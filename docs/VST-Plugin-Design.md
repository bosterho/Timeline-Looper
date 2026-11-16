# Timeline Looper — VST Plugin Design

Status: exploratory design. Captures the market rationale and architecture decisions
for porting the REAPER Timeline Looper concept into a cross-DAW VST3 plugin.

---

## 1. Product thesis

**Not "another looper" — the looper whose recorded performance is a re-editable timeline.**

Live looping (record/overdub/quantize/sync) is solved and saturated. The unoccupied
axis is **non-destructive, re-editable loop history on a linear timeline**: record live,
then move / mute / delete any layer *after the fact* and replay the take deterministically,
without re-recording.

Layers are identified by **MIDI note** ("by note, not by name"). Move a layer's note/clip,
and it plays back at the new location.

### Competitive position (from research)

| Tool | Surface | Editable history | Linear time-travel |
|---|---|---|---|
| Mobius | own | stack / undo only | ✗ |
| Loopy Pro | own (grid) | "Loop Peel" = stack pop | ✗ |
| Playtime 2 (REAPER) | own (grid) | remove clips, no time position | ✗ |
| Ableton Looper | host device | ✗ | ✗ |
| **This** | **own (timeline)** | **move / mute / delete per layer** | **✓** |

Closest competitor: **Playtime 2** (helgoboss, REAPER-native, MIDI-triggerable, tempo-synced).
It is a **grid/session** model — no linear time position per layer. That gap is our product.

Verdict: looping is saturated; the **timeline-integrated, non-destructive, time-travel**
niche is open. Do not compete on clip-launching polish; compete on the timeline paradigm.

---

## 2. Architecture decisions (and why)

The design converged through a sequence of choices:

1. **ARA?** No. ARA's model (audio source → modification → playback region) maps almost
   perfectly to "non-destructive repositionable layers," which *validates* the concept —
   but ARA edits audio that already exists, it doesn't record; for REAPER it's redundant
   with native items; and it excludes Ableton (no ARA support) and is shaky on Apple-Silicon
   Logic. We build our **own** ARA-like model instead.

2. **Can a VST know the host timeline?** No — a plugin is downstream of the playhead. It
   cannot enumerate clips, look ahead, or be told a note moved. BUT for playback we don't
   need that: **the note's position is communicated by *when* the host delivers its note-on.**
   Move the note → host delivers note-on at the new time → we play the buffer there.

3. **Own internal timeline.** To get look-ahead/pre-roll and full editing, the plugin owns
   a timeline in its **own UI**, synced to the host transport. This gives omniscience the
   host would never expose. (Chosen over host-native MIDI-on-tracks, which loses look-ahead.)

4. **Standalone app?** No. Standalone *maximizes* the "DAW within a DAW" problem (you rebuild
   audio drivers, transport, mixing, file handling) and **kills the differentiator**, which is
   *DAW-integrated* editing of a take in context. Stay a plugin.

5. **One global instance vs. per-track instances?** **Per-track instances.** Per-track FX/mixing
   is the entire reason to be a plugin — you inherit the DAW mixer for free. One global instance
   forces an internal mixer/FX system = DAW-within-a-DAW, worse. Layers within one track share a
   source and rarely need different FX, so per-track is the right granularity.

6. **Master UI vs per-track UI?** Neither — **one UI codebase, many identical views onto one
   shared document.** Not copies (copies desync). Every instance opens the same editor pointed at
   the same model; edits propagate via observer; all windows repaint.

This is the **current REAPER topology re-expressed**: per-track JSFX → plugin instances,
gmem → global coordinator, Lua/ImGui window → shared timeline view, A/B double-buffer → RCU snapshot.

---

## 3. Runtime structure

```
PluginInstance (per track)          N of these, one per track
   ├─ owns: audio I/O, trackId, PDC compensation
   ├─ references (not owns): Coordinator
   └─ Editor window = a VIEW (registers as listener)

Coordinator (per project, not per process)   exactly 1 per project
   ├─ owns: Document (master copy)
   ├─ owns: AudioPool (recorded buffers)
   ├─ owns: instance registry + listener list
   └─ publishes: immutable snapshots to audio threads
```

### Two-tier model — small/mutable control vs big/immutable audio

Mirrors the existing gmem-control vs audio-buffer split. Edits clone only the *small* Document
(kilobytes); audio is referenced by `BufferId`/`shared_ptr`, never copied.

```cpp
// SMALL — cloned on every edit (cheap). ~ gmem control slots.
struct Document {
    double tempoFallback;
    int    crossfadeMs;
    std::vector<TrackLane> lanes;
};
struct TrackLane {
    int trackId;
    std::vector<Clip> recClips;          // "rec" regions
    std::vector<Clip> playClips;         // "play" regions
};
struct Clip {
    int     noteId;                      // MIDI note = layer identity
    double  startBeats, lengthBeats;     // position on internal timeline
    double  playrate;
    BufferId source;                     // -> AudioPool, NOT inline audio
    Envelope volume, pan;                // ~ gmem 5000+/7000+ envelopes
};

// BIG — never cloned, ref-counted, shared by pointer. ~ A/B buffers.
struct AudioBuffer { std::vector<float> samples; int channels; double sampleRate; };
using BufferId = uint64_t;
class AudioPool {
    std::unordered_map<BufferId, std::shared_ptr<const AudioBuffer>> buffers;
};
```

### Thread-safe edits (RCU / snapshot publish)

Message thread mutates master, publishes an immutable clone; audio thread reads atomically.
No locks on the audio thread. Old snapshots free on whichever thread drops the last ref, but
only release *control* structs — big audio is co-owned by AudioPool, never freed on audio thread.

```cpp
class Coordinator {
    Document master;                                  // message thread only
    std::shared_ptr<const Document> liveSnapshot;     // atomic

    void applyEdit(std::function<void(Document&)> edit) {     // MESSAGE THREAD
        edit(master);
        auto snap = std::make_shared<const Document>(master); // clone (small)
        std::atomic_store(&liveSnapshot, snap);
        notifyListeners();
    }
    std::shared_ptr<const Document> getSnapshot() const {     // AUDIO THREAD
        return std::atomic_load(&liveSnapshot);
    }
};
```

### Per-project coordinator (permanent fix for the gmem-collision class of bug)

Scope the coordinator by a host-stable `ProjectKey`, so two open projects never share state.
This is the structural generalization of the gmem `AUDIO_BASE` 10000→30000 fix.

```cpp
class CoordinatorRegistry {                  // the only true process-global
    std::unordered_map<ProjectKey, std::shared_ptr<Coordinator>> perProject;
    std::mutex m;                             // message thread only; never audio
public:
    std::shared_ptr<Coordinator> attach(ProjectKey key, int trackId) {
        std::lock_guard lk(m);
        auto& c = perProject[key];
        if (!c) c = std::make_shared<Coordinator>();
        c->registerInstance(trackId);
        return c;
    }
};
```
`ProjectKey`: hash a per-project GUID stored in plugin state on first load (host project/session
context where available).

### Views (one model, many identical views)

```cpp
struct DocumentListener { virtual void documentChanged() = 0; };

class TimelineEditor : public juce::Component, public DocumentListener {
    Coordinator& coord;
    ViewState local;        // zoom, scroll, selection — LOCAL, never shared
    void documentChanged() override { repaint(); }
    void onClipDragged(int noteId, double newStart) {
        coord.applyEdit([=](Document& d){ d.moveClip(noteId, newStart); });
    }
};
```

**Shared vs local state boundary** (get this right or windows fight / desync):

| Document state (shared, one copy) | View state (local, per-window) |
|---|---|
| Clips, positions, layer→buffer mapping | Zoom level |
| Envelopes, layer mute/solo | Scroll position |
| Master timeline & clock | Selected clip in *this* window |

### Each instance has two separable roles
1. **Audio engine** bound to its own track (per-instance — captures its input, renders its lane).
2. **Window** viewing the whole shared document (global). Optional nicety: default-focus its own lane.

### Save/load — decentralized at rest, centralized at runtime
- Each instance saves **only its own lane** (+ that lane's buffers) into its own state chunk.
- Global settings (tempo fallback, crossfade, timeline length) saved redundantly by every
  instance, last-loaded-wins. No fragile "designated master."
- On load, each instance re-attaches and re-publishes its lane; coordinator reassembles.
- Buffers: serialize into the instance chunk, or to a project-relative file referenced by `BufferId`.

---

## 4. Host transport mapping (the sharp edge)

The plugin's internal timeline must follow the host playhead robustly across **play/stop, loops,
jumps, and tempo changes**. Each block the host provides a process context (VST3 `ProcessContext` /
JUCE `AudioPlayHead::PositionInfo`): tempo, time sig, `isPlaying`, `isLooping`, loop start/end, and
**`ppqPosition`** (project position in quarter notes) + sample position.

### Principle: drive the internal timeline from musical position, not by accumulating samples

Use the host's `ppqPosition` as the authoritative clock. Convert to internal-timeline beats:

```
internalBeat = hostPpq - sessionOriginPpq      // origin = where our timeline 0 sits in the host
```

Per block:
```cpp
void PluginInstance::processBlock(buffer, ph) {
    auto pos = ph.getPosition();
    if (!pos->getIsPlaying()) { renderTailsOnly(buffer); return; }

    double ppqStart = *pos->getPpqPosition();
    double bpm      = *pos->getBpm();
    double ppqPerSample = bpm / 60.0 / sampleRate;     // quarter-notes advanced per sample

    auto doc = coordinator->getSnapshot();
    for (int s = 0; s < buffer.getNumSamples(); ++s) {
        double beat = (ppqStart + s * ppqPerSample) - sessionOriginPpq;
        renderClipsAtBeat(doc, beat, buffer, s);       // sample-accurate playback position
    }
}
```

Why musical position, not a sample counter: a free-running sample counter desyncs the instant the
user loops, relocates, or changes tempo. `ppqPosition` is supplied by the host every block and is
always correct relative to the song — so **all per-track instances stay phase-locked for free**
(they all read the same host clock; no cross-instance time messaging needed).

### Handling the hard cases

- **Transport jump / user moves playhead:** detect a discontinuity (`ppqPosition` jumps vs.
  expected `prevPpq + blockBeats`). On jump: stop voices whose clips no longer cover `beat`,
  start voices whose clips now do, **mid-clip** — seek into the buffer at the right offset so a
  layer you jump into the middle of plays from the correct sample.
- **Loop (host repeat):** when `isLooping` and the playhead wraps loopEnd→loopStart, treat it as
  a jump back to loopStart; restart/seek voices accordingly. (Watch for the block that *straddles*
  the loop boundary — split it at the wrap point.)
- **Tempo changes / tempo map:** prefer the host's `ppqPosition` directly (it already bakes in the
  tempo map) over integrating `bpm`. If you must integrate within a block, re-read `bpm` per block;
  for ramps, accept per-block granularity or query the host tempo map if exposed.
- **Stop:** keep rendering decaying tails / crossfade tails after `isPlaying` goes false, then idle.

### Pre-roll / look-ahead (the payoff of owning the timeline)
Because we know every clip's `startBeats` ahead of the playhead, we can **begin reading a buffer
slightly before** its nominal start (attack lead-in, crossfade pre-roll) — the thing host-native
MIDI triggering can't do. Report latency (PDC) so the host aligns our output, reusing the existing
PDC approach (per-instance, summed over downstream FX).

### Recording path
Record events (rec clips) capture incoming audio into the AudioPool keyed by `noteId`. Index the
write position by **real transport time** (`rpos = beat - pdcBeats`), matching the existing rule:
record indexes to real transport, playback uses raw play position (downstream FX delay cancels).
On take complete, the buffer becomes immutable in the pool; the rec clip references it; a play clip
can then schedule it anywhere on the timeline.

---

## 5. Open questions / next

- `ProjectKey` derivation per host (REAPER, Cubase, Logic, Studio One) — confirm a stable source.
- Overdub model: stacked buffers per noteId vs. a single mixed buffer (stacked preserves per-layer
  time-travel; mixed is cheaper). Lean stacked to keep the differentiator.
- Buffer persistence: inline in state chunk vs. project-relative files (large-take handling).
- Block-straddle handling for loop boundaries and clip starts (split blocks at boundaries).
- UI scope for v1: timeline view + drag/mute/delete; defer envelopes editing.
- Validate the gap hands-on: build a 3-layer loop in **Playtime 2**, confirm it cannot do
  linear per-layer time-travel.

---

## Mapping: current REAPER design → VST

| Lua / gmem (now) | VST |
|---|---|
| gmem control slots | `Document` / `TrackLane` / `Clip` |
| A/B audio buffers | `AudioPool` + `shared_ptr<AudioBuffer>` |
| gmem `AUDIO_BASE` namespacing | `ProjectKey`-scoped coordinator |
| Lua/ImGui single window | `TimelineEditor` shared view |
| Per-track JSFX instance | `PluginInstance` |
| Double-buffer swap on advance | RCU snapshot publish |
| PDC via gmem[900+idx] | per-instance PDC at render |
| record indexes to real transport | `rpos = beat - pdcBeats` |
