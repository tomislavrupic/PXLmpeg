# PXLmpeg / Pixel Deck signal-flow infographic

Generated with the built-in imagegen tool on 14 October 2026. The PXLmpeg app icon is a style reference. This depicts the planned engine/consumer boundary, not implemented professional codec support. Intended image: `pxlmpeg-signal-flow-v1.png`.

## Prompt

Use case: infographic-diagram.
Create a polished, highly legible landscape technical infographic for the PXLmpeg and Pixel Deck project. This is a TARGET architecture diagram, not a claim of already shipped features. Style reference: the attached PXLmpeg app icon, used for its restrained near-black charcoal, mint glass accents and fine instrument lines. Incorporate a small version of its pixel/play mark beside the title. Predominantly flat, precise infographic with subtle glass panels; no perspective diagram, no photorealism, no tiny dense paragraphs. Wide horizontal layout, generous spacing and large crisp sans-serif typography, readable on a laptop. Mint video path, lavender audio path, softly amber optional analysis path. Clear arrowheads and no crossing wires. All labels must be spelled correctly.

Top title, exact: "PXLmpeg → Pixel Deck"
Subtitle, exact: "Professional media signal flow"
Visible status badge: "TARGET ARCHITECTURE · EARLY RESEARCH"

Main upper flow goes LEFT TO RIGHT:
1. Source card titled "SOURCE MEDIA", with stacked labels:
"Current: H.264 / HEVC · MOV / MP4"
"Next: ProRes MOV + PCM"
"Research: MXF / XAVC"
Small caption: "Originals stay read-only"

2. Large group titled "PXLmpeg · NATIVE MEDIA ENGINE", containing two consecutive simple blocks connected left-to-right:
"Inspect + demux"
caption: "Tracks · colour · timestamps"
then "Decode + buffer"
caption: "Native frames · bounded queues"
An arrow from SOURCE MEDIA enters Inspect. An arrow connects Inspect to Decode.
At the right edge of this group, Decode splits cleanly into TWO outgoing horizontal paths.

3. Large group to its RIGHT titled "PIXEL DECK". Label the connecting boundary "Frame / audio adapter · planned".
The top incoming mint path is labeled "VIDEO FRAMES" and enters a block titled "Metal colour + LUTs".
The lower incoming lavender path is labeled "PCM AUDIO" and enters a separate block titled "Clock + audio routing".
Keep the video and audio paths independent, parallel, and clearly separated.

4. At far right: top video output card "PICTURE OUTPUTS" with "Mac · DeckLink · HDMI · iPad"; bottom audio output card "SOUND OUTPUTS" with "Core Audio devices". Connect only the video block to picture outputs and only the audio block to sound outputs.

Lower lane: a dashed amber branch from PXLmpeg's Decode + buffer block, labeled "Sample frames", feeds three left-to-right cards:
"OPTIONAL ANALYSIS" with small caption "Core ML"
then "TIMESTAMPED INDEX"
then "SEARCH + AI TOOLS" with caption "Source · moment · preview".
A thin dashed return arrow from SEARCH + AI TOOLS to the Pixel Deck group is labeled "Jump to moment".
This analysis lane must look secondary and must not sit in series with normal playback. No arrows through AI on the main video/audio paths.

Bottom footer, exact text: "Swift + Metal · Apple system frameworks · Zero third-party dependencies in the core"
Second smaller footer: "ProRes / PCM delivery and Pixel Deck integration are planned; codec hardware support is verified per profile."
No additional invented features, promises, statistics or slogans. No claim that every codec uses hardware or that all AI work runs on the Neural Engine. One finished infographic, not a mockup, no watermark.

