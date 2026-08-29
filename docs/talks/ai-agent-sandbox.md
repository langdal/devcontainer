---
marp: true
theme: default
paginate: true
title: Sandboxing AI Agents
author: Jakob Langdal
style: |
  section {
    --accent: #4c5fd7;
    --danger: #e03131;
    --ink: #1a1d23;
    --muted: #6b7280;
    --paper: #fbfbfa;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
    font-size: 25px;
    line-height: 1.5;
    padding: 55px 70px;
    background: var(--paper);
    color: var(--ink);
  }
  section h1 {
    font-size: 1.9em;
    line-height: 1.15;
    letter-spacing: -0.025em;
    color: var(--ink);
    margin: 0 0 0.6em 0;
    padding-bottom: 0.18em;
    border-bottom: 4px solid var(--accent);
  }
  section h2 {
    font-size: 1.15em;
    color: var(--accent);
    margin: 0.9em 0 0.3em 0;
    letter-spacing: 0.01em;
  }
  section strong { color: var(--accent); font-weight: 700; }
  section code {
    background: #eceef3;
    color: #202430;
    padding: 0.1em 0.35em;
    border-radius: 4px;
    font-size: 0.9em;
  }
  section pre {
    background: #14171d;
    border-radius: 8px;
    padding: 0.9em 1.1em;
    font-size: 0.78em;
    line-height: 1.7;
  }
  section pre code { background: transparent; color: #e6e8ee; }
  section pre code span[class] { color: #e6e8ee; font-weight: 400; }
  section pre code span.hljs-comment { color: #8891a3; font-style: italic; }
  section pre code span.hljs-string { color: #b8dba0; }
  section pre code span.hljs-built_in,
  section pre code span.hljs-keyword { color: #9fc0ff; }
  section pre code span.hljs-variable,
  section pre code span.hljs-subst,
  section pre code span.hljs-meta { color: #ffd08a; }
  section ul, section ol { margin: 0.3em 0; }
  section li { margin: 0.32em 0; }
  section blockquote {
    border-left: 4px solid var(--muted);
    margin: 0.7em 0;
    padding: 0.1em 0 0.1em 0.9em;
    color: var(--muted);
    font-style: normal;
  }
  section .cols { display: grid; grid-template-columns: 1fr 1fr; gap: 0.6em 2em; }
  section .kicker {
    color: var(--muted);
    text-transform: uppercase;
    letter-spacing: 0.12em;
    font-size: 0.62em;
    font-weight: 700;
    margin-bottom: 0.35em;
  }
  section .big { font-size: 1.25em; line-height: 1.35; }
  section .note { color: var(--muted); font-size: 0.85em; }
  section .fig { text-align: center; margin: 0.5em 0 0.2em 0; }
  section .fig svg { max-width: 100%; height: auto; }
  section.lead { justify-content: center; text-align: left; }
  section.lead h1 { font-size: 2.6em; border-bottom: none; padding: 0; margin-bottom: 0.15em; }
  section.lead h3 { color: var(--muted); font-weight: 400; font-size: 1.15em; margin: 0 0 1.6em 0; }
  section footer { color: var(--muted); font-size: 0.6em; }
  section::after { color: var(--muted); font-size: 0.6em; }
---

<!-- _class: lead -->
<!-- _paginate: false -->

# Sandboxing AI agents

### Why you probably want one, and one way to get it

Jakob Langdal

---

<div class="kicker">how we got here</div>

# The agent left the editor

<div class="fig">

<svg viewBox="0 0 900 320" width="860">
  <rect x="6" y="8" width="278" height="268" rx="12" fill="#ffffff" stroke="#c7cbd6" stroke-width="2"/>
  <text x="145" y="40" text-anchor="middle" font-size="13" font-weight="700" fill="#6b7280" letter-spacing="2">IN THE EDITOR</text>
  <rect x="95" y="76" width="100" height="36" rx="8" fill="#4c5fd7"/>
  <text x="145" y="100" text-anchor="middle" font-size="16" font-weight="700" fill="#ffffff">you</text>
  <path d="M145 118 V152" stroke="#6b7280" stroke-width="3"/>
  <path d="M137 124 L145 112 L153 124 Z" fill="#6b7280"/>
  <path d="M137 146 L145 158 L153 146 Z" fill="#6b7280"/>
  <rect x="70" y="158" width="150" height="48" rx="8" fill="#ffffff" stroke="#c7cbd6" stroke-width="2"/>
  <text x="145" y="180" text-anchor="middle" font-size="15" fill="#1a1d23">the file</text>
  <text x="145" y="198" text-anchor="middle" font-size="12" fill="#6b7280" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">src/game.js</text>
  <text x="145" y="246" text-anchor="middle" font-size="13" fill="#c7cbd6" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">tab · tab · tab</text>

  <rect x="306" y="8" width="278" height="268" rx="12" fill="#ffffff" stroke="#c7cbd6" stroke-width="2"/>
  <text x="445" y="40" text-anchor="middle" font-size="13" font-weight="700" fill="#6b7280" letter-spacing="2">IN THE CHAT</text>
  <rect x="370" y="76" width="150" height="36" rx="8" fill="#4c5fd7"/>
  <text x="445" y="100" text-anchor="middle" font-size="16" font-weight="700" fill="#ffffff">you</text>
  <path d="M445 112 V124" stroke="#6b7280" stroke-width="3"/>
  <path d="M438 124 L445 134 L452 124 Z" fill="#6b7280"/>
  <rect x="370" y="134" width="150" height="36" rx="8" fill="#ffffff" stroke="#c7cbd6" stroke-width="2"/>
  <text x="445" y="158" text-anchor="middle" font-size="15" fill="#1a1d23">the agent</text>
  <path d="M445 170 V182" stroke="#6b7280" stroke-width="3"/>
  <path d="M438 182 L445 192 L452 182 Z" fill="#6b7280"/>
  <rect x="370" y="192" width="150" height="36" rx="8" fill="#eceef3"/>
  <text x="445" y="216" text-anchor="middle" font-size="15" fill="#1a1d23">a diff</text>
  <path d="M520 210 C 562 210 562 94 530 94" stroke="#6b7280" stroke-width="2.5" fill="none"/>
  <path d="M534 88 L522 94 L534 100 Z" fill="#6b7280"/>
  <text transform="translate(574,127) rotate(90)" font-size="12" fill="#6b7280" font-style="italic">review</text>

  <rect x="606" y="8" width="288" height="268" rx="12" fill="#ffffff" stroke="#4c5fd7" stroke-width="2.5"/>
  <text x="750" y="40" text-anchor="middle" font-size="13" font-weight="700" fill="#4c5fd7" letter-spacing="2">IN A LOOP</text>
  <circle cx="750" cy="150" r="58" fill="none" stroke="#4c5fd7" stroke-width="2.5" stroke-dasharray="7 6"/>
  <path d="M744 86 L756 92 L744 98 Z" fill="#4c5fd7"/>
  <path d="M802 144 L808 156 L814 144 Z" fill="#4c5fd7"/>
  <path d="M686 156 L692 144 L698 156 Z" fill="#4c5fd7"/>
  <text x="750" y="155" text-anchor="middle" font-size="13" fill="#6b7280">the agent</text>
  <rect x="757" y="97" width="72" height="24" rx="6" fill="#eceef3"/>
  <text x="793" y="114" text-anchor="middle" font-size="13" fill="#1a1d23">design</text>
  <rect x="757" y="179" width="72" height="24" rx="6" fill="#eceef3"/>
  <text x="793" y="196" text-anchor="middle" font-size="13" fill="#1a1d23">plan</text>
  <rect x="671" y="179" width="72" height="24" rx="6" fill="#eceef3"/>
  <text x="707" y="196" text-anchor="middle" font-size="13" fill="#1a1d23">build</text>
  <rect x="671" y="97" width="72" height="24" rx="6" fill="#eceef3"/>
  <text x="707" y="114" text-anchor="middle" font-size="13" fill="#1a1d23">test</text>
  <path d="M750 208 V218" stroke="#6b7280" stroke-width="2.5" stroke-dasharray="5 4"/>
  <path d="M743 216 L750 226 L757 216 Z" fill="#6b7280"/>
  <rect x="700" y="230" width="100" height="34" rx="8" fill="#4c5fd7"/>
  <text x="750" y="253" text-anchor="middle" font-size="16" font-weight="700" fill="#ffffff">you</text>

  <text x="145" y="304" text-anchor="middle" font-size="15" fill="#6b7280">you are in every keystroke</text>
  <text x="445" y="304" text-anchor="middle" font-size="15" fill="#6b7280">you are in every step</text>
  <text x="750" y="304" text-anchor="middle" font-size="15" font-weight="700" fill="#4c5fd7">you are at the end</text>
</svg>

</div>

<div class="big">

Each step right is more value — because there is **less of you** in it.

</div>

---

<div class="kicker">10:02 — a real agentic run</div>

# We give it something big

<div class="fig">

<svg viewBox="0 0 900 230" width="700">
  <rect x="10" y="10" width="880" height="210" rx="14" fill="#14171d"/>
  <circle cx="38" cy="38" r="7" fill="#e03131"/><circle cx="60" cy="38" r="7" fill="#d9a441"/><circle cx="82" cy="38" r="7" fill="#3fa662"/>
  <text x="36" y="86" font-size="19" fill="#e6e8ee" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">Build me a DOOM-style shooter in plain JavaScript.</text>
  <text x="36" y="114" font-size="19" fill="#e6e8ee" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">Pokémon as the monsters. Raycast renderer, 151 sprites,</text>
  <text x="36" y="142" font-size="19" fill="#e6e8ee" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">chiptune soundtrack, procedural mazes, high-score board.</text>
  <text x="36" y="176" font-size="19" fill="#e6e8ee" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">Set up repo, tests, dev server. <tspan fill="#9aa3c0">Keep going until every</tspan></text>
  <text x="36" y="204" font-size="19" fill="#9aa3c0" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">goal is satisfied — don't stop to ask. k bye ☕</text>
</svg>

</div>

---

<div class="kicker">10:04 → 10:19 — the first nine prompts</div>

# And then it starts asking

<div class="fig">

<svg viewBox="0 0 900 200" width="860">
  <rect x="15" y="20" width="130" height="78" rx="8" fill="#ffffff" stroke="#c7cbd6" stroke-width="1.5"/>
  <text x="27" y="43" font-size="13" font-weight="700" fill="#1a1d23">Allow?</text>
  <text x="27" y="62" font-size="10.5" fill="#6b7280" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">npm install</text>
  <rect x="27" y="72" width="48" height="17" rx="4" fill="#4c5fd7"/>
  <text x="51" y="84.5" font-size="10" fill="#ffffff" text-anchor="middle" font-weight="600">Allow</text>
  <rect x="15" y="122" width="130" height="9" rx="4.5" fill="#eceef3"/>
  <rect x="15" y="122" width="126" height="9" rx="4.5" fill="#4c5fd7"/>
  <text x="80" y="152" font-size="12" fill="#6b7280" text-anchor="middle">read it</text>

  <rect x="160" y="20" width="130" height="78" rx="8" fill="#ffffff" stroke="#c7cbd6" stroke-width="1.5"/>
  <text x="172" y="43" font-size="13" font-weight="700" fill="#1a1d23">Allow?</text>
  <text x="172" y="62" font-size="10.5" fill="#6b7280" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">mkdir assets</text>
  <rect x="172" y="72" width="48" height="17" rx="4" fill="#4c5fd7"/>
  <text x="196" y="84.5" font-size="10" fill="#ffffff" text-anchor="middle" font-weight="600">Allow</text>
  <rect x="160" y="122" width="130" height="9" rx="4.5" fill="#eceef3"/>
  <rect x="160" y="122" width="96" height="9" rx="4.5" fill="#4c5fd7"/>
  <text x="225" y="152" font-size="12" fill="#6b7280" text-anchor="middle">read most</text>

  <rect x="305" y="20" width="130" height="78" rx="8" fill="#ffffff" stroke="#c7cbd6" stroke-width="1.5"/>
  <text x="317" y="43" font-size="13" font-weight="700" fill="#1a1d23">Allow?</text>
  <text x="317" y="62" font-size="10.5" fill="#6b7280" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">curl -O sprites</text>
  <rect x="317" y="72" width="48" height="17" rx="4" fill="#4c5fd7"/>
  <text x="341" y="84.5" font-size="10" fill="#ffffff" text-anchor="middle" font-weight="600">Allow</text>
  <rect x="305" y="122" width="130" height="9" rx="4.5" fill="#eceef3"/>
  <rect x="305" y="122" width="62" height="9" rx="4.5" fill="#4c5fd7"/>
  <text x="370" y="152" font-size="12" fill="#6b7280" text-anchor="middle">skimmed</text>

  <rect x="450" y="20" width="130" height="78" rx="8" fill="#ffffff" stroke="#c7cbd6" stroke-width="1.5"/>
  <text x="462" y="43" font-size="13" font-weight="700" fill="#1a1d23">Allow?</text>
  <text x="462" y="62" font-size="10.5" fill="#6b7280" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">rm -rf dist</text>
  <rect x="462" y="72" width="48" height="17" rx="4" fill="#4c5fd7"/>
  <text x="486" y="84.5" font-size="10" fill="#ffffff" text-anchor="middle" font-weight="600">Allow</text>
  <rect x="450" y="122" width="130" height="9" rx="4.5" fill="#eceef3"/>
  <rect x="450" y="122" width="30" height="9" rx="4.5" fill="#4c5fd7"/>
  <text x="515" y="152" font-size="12" fill="#6b7280" text-anchor="middle">glanced</text>

  <rect x="595" y="20" width="130" height="78" rx="8" fill="#ffffff" stroke="#c7cbd6" stroke-width="1.5"/>
  <text x="607" y="43" font-size="13" font-weight="700" fill="#1a1d23">Allow?</text>
  <text x="607" y="62" font-size="10.5" fill="#6b7280" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">git commit -am …</text>
  <rect x="607" y="72" width="48" height="17" rx="4" fill="#4c5fd7"/>
  <text x="631" y="84.5" font-size="10" fill="#ffffff" text-anchor="middle" font-weight="600">Allow</text>
  <rect x="595" y="122" width="130" height="9" rx="4.5" fill="#eceef3"/>
  <rect x="595" y="122" width="9" height="9" rx="4.5" fill="#4c5fd7"/>
  <text x="660" y="152" font-size="12" fill="#6b7280" text-anchor="middle">clicked</text>

  <text x="800" y="78" font-size="34" fill="#c7cbd6" text-anchor="middle">· · ·</text>
  <text x="800" y="152" font-size="12" fill="#6b7280" text-anchor="middle" font-style="italic">still going</text>
</svg>

</div>

---

<div class="kicker">10:21 — number ten</div>

# So we make it stop

<div class="fig">

<svg viewBox="0 0 900 290" width="820">
  <rect x="60" y="8" width="780" height="274" rx="14" fill="#ffffff" stroke="#c7cbd6" stroke-width="2"/>
  <text x="96" y="52" font-size="21" font-weight="700" fill="#1a1d23">Allow this command?</text>
  <rect x="96" y="68" width="708" height="42" rx="6" fill="#14171d"/>
  <text x="112" y="95" font-size="15" fill="#e6e8ee" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">find assets -name '*.png' | xargs -n1 identify -format '%wx%h\n'</text>
  <rect x="96" y="126" width="708" height="38" rx="8" fill="#eceef3"/>
  <text x="114" y="151" font-size="16" fill="#1a1d23">1. Yes, this time</text>
  <rect x="96" y="172" width="708" height="38" rx="8" fill="#4c5fd7"/>
  <text x="114" y="197" font-size="16" fill="#ffffff" font-weight="700">2. Yes, and don't ask again for <tspan font-family="ui-monospace, SFMono-Regular, Menlo, monospace">xargs *</tspan></text>
  <path d="M742 186 l26 22 -9 2 6 13 -6 3 -6 -13 -7 6 Z" fill="#ffffff" stroke="#1a1d23" stroke-width="1.5"/>
  <rect x="96" y="218" width="708" height="38" rx="8" fill="#eceef3"/>
  <text x="114" y="243" font-size="16" fill="#1a1d23">3. No, tell the agent what to do instead</text>
</svg>

</div>

---

<div class="kicker">10:22 — you leave</div>

# It works! It really works

<div class="fig">

<svg viewBox="0 0 900 250" width="820">
  <rect x="10" y="10" width="660" height="230" rx="12" fill="#14171d"/>
  <text x="34" y="52" font-size="16" fill="#3fa662" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">✓ <tspan fill="#e6e8ee">wrote src/engine/raycaster.js</tspan></text>
  <text x="34" y="84" font-size="16" fill="#3fa662" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">✓ <tspan fill="#e6e8ee">generated 151 sprite billboards</tspan></text>
  <text x="34" y="116" font-size="16" fill="#3fa662" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">✓ <tspan fill="#e6e8ee">npm test — 42 passing</tspan></text>
  <text x="34" y="148" font-size="16" fill="#3fa662" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">✓ <tspan fill="#e6e8ee">xargs -n1 identify … (auto-approved)</tspan></text>
  <text x="34" y="180" font-size="16" fill="#3fa662" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">✓ <tspan fill="#e6e8ee">sprite sheet packed</tspan></text>
  <text x="34" y="212" font-size="16" fill="#6b7280" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">  <tspan fill="#8d94a8">searching for higher-res source art…</tspan></text>
  <g transform="translate(740,84)">
    <path d="M0 20 h70 v40 a20 20 0 0 1 -20 20 h-30 a20 20 0 0 1 -20 -20 Z" fill="#eceef3" stroke="#c7cbd6" stroke-width="2"/>
    <path d="M70 30 h12 a15 15 0 0 1 0 30 h-12" fill="none" stroke="#c7cbd6" stroke-width="2"/>
    <path d="M18 12 q7 -9 0 -18 M36 12 q7 -9 0 -18 M54 12 q7 -9 0 -18" stroke="#c7cbd6" stroke-width="2" fill="none"/>
  </g>
</svg>

</div>

---

<div class="kicker">11:40 — you come back</div>

# "Done! I found tons of Pokémon art"

<div class="fig">

<svg viewBox="0 0 900 310" width="800">
  <rect x="10" y="10" width="880" height="292" rx="14" fill="#ffffff" stroke="#c7cbd6" stroke-width="2"/>
  <circle cx="52" cy="52" r="17" fill="#2f9e44"/>
  <path d="M44 52 l6 7 l12 -14" stroke="#ffffff" stroke-width="3.5" fill="none" stroke-linecap="round" stroke-linejoin="round"/>
  <text x="84" y="59" font-size="20" font-weight="700" fill="#1a1d23">Done — every goal satisfied.</text>
  <text x="84" y="100" font-size="16" fill="#1a1d23">Doom-Pokémon runs at 60 fps. 42 tests passing. Chiptune loops.</text>
  <text x="84" y="138" font-size="16" fill="#1a1d23">Sprite art was thin online, so I checked the hosts you have access to.</text>
  <text x="84" y="166" font-size="16" fill="#1a1d23">gpu-lab-01 was empty — but client-backup had a large image cache:</text>
  <rect x="84" y="184" width="600" height="36" rx="6" fill="#eceef3"/>
  <text x="100" y="208" font-size="15" fill="#202430" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">/srv/restores/2021/acme-corp/marketing/assets/</text>
  <text x="84" y="250" font-size="16" fill="#1a1d23">4,812 images. I picked the 151 best matches and copied them into</text>
  <text x="84" y="274" font-size="16" fill="#1a1d23" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">assets/sprites/<tspan font-family="-apple-system, BlinkMacSystemFont, Segoe UI, Roboto, sans-serif">.  Want me to open a PR?</tspan></text>
</svg>

</div>

---

<div class="kicker">11:41 — you scroll up</div>

# One of those was this

<div class="fig">

<svg viewBox="0 0 900 300" width="840">
  <rect x="10" y="8" width="880" height="122" rx="10" fill="#14171d" stroke="#e03131" stroke-width="2.5"/>
  <text x="34" y="44" font-size="15" fill="#e6e8ee" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">awk '/^Host /{print $2}' ~/.ssh/config \</text>
  <text x="34" y="72" font-size="15" fill="#e6e8ee" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">  | <tspan fill="#ff8787" font-weight="700">xargs</tspan> -P8 -I% ssh -o BatchMode=yes % \</text>
  <text x="34" y="100" font-size="15" fill="#e6e8ee" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">      'find / -iname "*pokemon*" -o -iname "*sprite*" 2>/dev/null'</text>

  <rect x="10" y="170" width="180" height="72" rx="10" fill="#ffffff" stroke="#c7cbd6" stroke-width="2"/>
  <text x="100" y="200" text-anchor="middle" font-size="15" font-weight="700" fill="#1a1d23">your laptop</text>
  <text x="100" y="224" text-anchor="middle" font-size="13" fill="#6b7280" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">~/.ssh/config</text>
  <path d="M198 206 H262" stroke="#e03131" stroke-width="3"/>
  <path d="M262 196 L284 206 L262 216 Z" fill="#e03131"/>
  <text x="240" y="192" text-anchor="middle" font-size="13" fill="#e03131" font-style="italic">your key, 8 at a time</text>

  <rect x="300" y="150" width="182" height="46" rx="8" fill="#fdeaea"/>
  <text x="391" y="179" text-anchor="middle" font-size="15" fill="#b02525" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">gpu-lab-01</text>
  <rect x="300" y="206" width="182" height="46" rx="8" fill="#fdeaea"/>
  <text x="391" y="235" text-anchor="middle" font-size="15" fill="#b02525" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">prod-deploy</text>
  <rect x="300" y="262" width="182" height="46" rx="8" fill="#fdeaea"/>
  <text x="391" y="291" text-anchor="middle" font-size="15" fill="#b02525" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">client-backup</text>

  <path d="M498 173 H540" stroke="#c7cbd6" stroke-width="2"/>
  <path d="M498 229 H540" stroke="#c7cbd6" stroke-width="2"/>
  <path d="M498 285 H540" stroke="#c7cbd6" stroke-width="2"/>
  <text x="556" y="180" font-size="15" fill="#1a1d23">a full <tspan font-family="ui-monospace, SFMono-Regular, Menlo, monospace">find /</tspan> on every host you can reach</text>
  <text x="556" y="236" font-size="15" fill="#1a1d23">in the logs, at 3 in the morning, as <tspan font-weight="700">you</tspan></text>
  <text x="556" y="292" font-size="15" fill="#1a1d23">a customer's machine, on a Pokémon errand</text>
</svg>

</div>

---

# You approved a shape, not a command

<div class="fig">

<svg viewBox="0 0 600 235" width="600">
  <rect x="15" y="15" width="570" height="205" rx="14" fill="#fdeaea" stroke="#e03131" stroke-width="2" stroke-dasharray="8 6"/>
  <text x="300" y="48" text-anchor="middle" font-size="15" font-weight="700" fill="#b02525" letter-spacing="1">THE RULE YOU WROTE: <tspan font-family="ui-monospace, SFMono-Regular, Menlo, monospace">xargs *</tspan></text>
  <rect x="45" y="66" width="255" height="34" rx="8" fill="#4c5fd7"/>
  <text x="172" y="89" text-anchor="middle" font-size="14" fill="#ffffff" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">xargs -n1 identify</text>
  <text x="314" y="89" font-size="14" fill="#6b7280" font-style="italic">← the one you saw</text>
  <rect x="45" y="112" width="245" height="32" rx="8" fill="#ffffff" stroke="#f0b8b8" stroke-width="1.5"/>
  <text x="167" y="134" text-anchor="middle" font-size="13.5" fill="#b02525" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">xargs ssh …</text>
  <rect x="302" y="112" width="245" height="32" rx="8" fill="#ffffff" stroke="#f0b8b8" stroke-width="1.5"/>
  <text x="424" y="134" text-anchor="middle" font-size="13.5" fill="#b02525" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">xargs rm -rf …</text>
  <rect x="45" y="156" width="245" height="32" rx="8" fill="#ffffff" stroke="#f0b8b8" stroke-width="1.5"/>
  <text x="167" y="178" text-anchor="middle" font-size="13.5" fill="#b02525" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">xargs curl … | sh</text>
  <rect x="302" y="156" width="245" height="32" rx="8" fill="#ffffff" stroke="#f0b8b8" stroke-width="1.5"/>
  <text x="424" y="178" text-anchor="middle" font-size="13.5" fill="#b02525" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">xargs docker run -v / …</text>
</svg>

</div>

> Nobody turns the prompts off because they are reckless. They turn them off because the prompts stopped carrying information.

---

# The prompt *was* the security model

Every "Allow?" was a human deciding whether the agent may:

<div class="cols">

- read **that** file
- run **that** command

- reach **that** host
- use **your** credentials

</div>

<div class="big">

Turning it off does not reduce what the agent **can do**.
It removes the only thing that was **limiting** it.

</div>

---

# "But we already run in a devcontainer"

<div class="fig">

<svg viewBox="0 0 900 300" width="840">
  <rect x="10" y="30" width="230" height="240" rx="12" fill="#ffffff" stroke="#c7cbd6" stroke-width="2"/>
  <text x="125" y="58" text-anchor="middle" font-size="13" font-weight="700" fill="#6b7280" letter-spacing="2">YOUR MACHINE</text>
  <rect x="30" y="76" width="180" height="28" rx="7" fill="#fdeaea"/>
  <text x="120" y="95" text-anchor="middle" font-size="12.5" fill="#b02525" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">ssh-agent</text>
  <rect x="30" y="112" width="180" height="28" rx="7" fill="#fdeaea"/>
  <text x="120" y="131" text-anchor="middle" font-size="12.5" fill="#b02525" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">gh token</text>
  <rect x="30" y="148" width="180" height="28" rx="7" fill="#fdeaea"/>
  <text x="120" y="167" text-anchor="middle" font-size="12.5" fill="#b02525" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">docker daemon</text>
  <rect x="30" y="184" width="180" height="28" rx="7" fill="#fdeaea"/>
  <text x="120" y="203" text-anchor="middle" font-size="12.5" fill="#b02525" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">~/.gitconfig</text>
  <rect x="30" y="220" width="180" height="28" rx="7" fill="#eceef3"/>
  <text x="120" y="239" text-anchor="middle" font-size="12.5" fill="#1a1d23" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">other repos</text>

  <rect x="372" y="14" width="18" height="272" rx="4" fill="#4c5fd7"/>
  <text transform="translate(358,150) rotate(-90)" text-anchor="middle" font-size="12" font-weight="700" fill="#4c5fd7" letter-spacing="2">THE MOUNT BOUNDARY</text>

  <rect x="520" y="30" width="370" height="240" rx="12" fill="#ffffff" stroke="#c7cbd6" stroke-width="2"/>
  <text x="705" y="58" text-anchor="middle" font-size="13" font-weight="700" fill="#6b7280" letter-spacing="2">THE DEVCONTAINER</text>
  <rect x="610" y="130" width="190" height="46" rx="8" fill="#4c5fd7"/>
  <text x="705" y="160" text-anchor="middle" font-size="16" fill="#ffffff" font-weight="600" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">/workspace</text>
  <text x="705" y="208" text-anchor="middle" font-size="14" fill="#6b7280">only the project is mounted</text>
  <text x="705" y="232" text-anchor="middle" font-size="14" fill="#6b7280">no home · no keys</text>
</svg>

</div>

<div class="big">

Fair question. This is the **right instinct** — and the right shape.

</div>

---

# It was built for a human operator

<div class="fig">

<svg viewBox="0 0 900 300" width="840">
  <rect x="10" y="30" width="230" height="240" rx="12" fill="#ffffff" stroke="#c7cbd6" stroke-width="2"/>
  <text x="125" y="58" text-anchor="middle" font-size="13" font-weight="700" fill="#6b7280" letter-spacing="2">YOUR MACHINE</text>
  <rect x="30" y="76" width="180" height="28" rx="7" fill="#fdeaea"/>
  <text x="120" y="95" text-anchor="middle" font-size="12.5" fill="#b02525" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">ssh-agent</text>
  <rect x="30" y="112" width="180" height="28" rx="7" fill="#fdeaea"/>
  <text x="120" y="131" text-anchor="middle" font-size="12.5" fill="#b02525" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">gh token</text>
  <rect x="30" y="148" width="180" height="28" rx="7" fill="#fdeaea"/>
  <text x="120" y="167" text-anchor="middle" font-size="12.5" fill="#b02525" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">docker daemon</text>
  <rect x="30" y="184" width="180" height="28" rx="7" fill="#fdeaea"/>
  <text x="120" y="203" text-anchor="middle" font-size="12.5" fill="#b02525" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">~/.gitconfig</text>
  <rect x="30" y="220" width="180" height="28" rx="7" fill="#eceef3"/>
  <text x="120" y="239" text-anchor="middle" font-size="12.5" fill="#1a1d23" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">other repos</text>

  <rect x="372" y="14" width="18" height="272" rx="4" fill="#4c5fd7"/>

  <rect x="520" y="30" width="370" height="240" rx="12" fill="#ffffff" stroke="#c7cbd6" stroke-width="2"/>
  <text x="705" y="58" text-anchor="middle" font-size="13" font-weight="700" fill="#6b7280" letter-spacing="2">THE DEVCONTAINER</text>

  <rect x="212" y="74" width="316" height="30" rx="8" fill="#fdeaea" stroke="#e03131" stroke-width="2"/>
  <text x="370" y="94" text-anchor="middle" font-size="13.5" fill="#b02525" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">SSH_AUTH_SOCK</text>
  <path d="M528 76 L548 89 L528 102 Z" fill="#e03131"/>
  <rect x="212" y="116" width="316" height="30" rx="8" fill="#fdeaea" stroke="#e03131" stroke-width="2"/>
  <text x="370" y="136" text-anchor="middle" font-size="13.5" fill="#b02525">git credential helper</text>
  <path d="M528 118 L548 131 L528 144 Z" fill="#e03131"/>
  <rect x="212" y="158" width="316" height="30" rx="8" fill="#fdeaea" stroke="#e03131" stroke-width="2"/>
  <text x="370" y="178" text-anchor="middle" font-size="13.5" fill="#b02525" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">/var/run/docker.sock</text>
  <path d="M528 160 L548 173 L528 186 Z" fill="#e03131"/>
  <rect x="212" y="200" width="316" height="30" rx="8" fill="#fdeaea" stroke="#e03131" stroke-width="2"/>
  <text x="370" y="220" text-anchor="middle" font-size="13.5" fill="#b02525">gitconfig · known_hosts · dotfiles</text>
  <path d="M528 202 L548 215 L528 228 Z" fill="#e03131"/>

  <text x="705" y="256" text-anchor="middle" font-size="14" fill="#6b7280" font-style="italic">…so that <tspan font-family="ui-monospace, SFMono-Regular, Menlo, monospace" font-style="normal">git push</tspan> just works</text>
</svg>

</div>

Every one of these was a **good** decision — for a **person** in that container.

---

# Same command. Same hosts

```bash
xargs -P8 -I% ssh -o BatchMode=yes % 'find / -iname "*pokemon*"'   # inside /workspace
```

<div class="fig">

<svg viewBox="0 0 900 210" width="840">
  <rect x="10" y="70" width="190" height="76" rx="10" fill="#ffffff" stroke="#c7cbd6" stroke-width="2"/>
  <text x="105" y="100" text-anchor="middle" font-size="15" font-weight="600" fill="#1a1d23">the devcontainer</text>
  <text x="105" y="124" text-anchor="middle" font-size="12.5" fill="#6b7280">no keys inside</text>
  <path d="M204 108 H318" stroke="#e03131" stroke-width="3"/>
  <path d="M318 100 L334 108 L318 116 Z" fill="#e03131"/>
  <text x="266" y="96" text-anchor="middle" font-size="12.5" fill="#b02525" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">SSH_AUTH_SOCK</text>
  <text x="266" y="132" text-anchor="middle" font-size="11.5" fill="#6b7280" font-style="italic">forwarded for you</text>
  <rect x="336" y="62" width="206" height="92" rx="10" fill="#ffffff" stroke="#4c5fd7" stroke-width="2.5"/>
  <text x="439" y="92" text-anchor="middle" font-size="15" font-weight="700" fill="#1a1d23">your ssh-agent</text>
  <text x="439" y="114" text-anchor="middle" font-size="12.5" fill="#6b7280">still on the host</text>
  <text x="439" y="142" text-anchor="middle" font-size="12.5" fill="#4c5fd7">signs whatever it is asked to</text>
  <path d="M546 108 L632 62" stroke="#e03131" stroke-width="2.5"/>
  <path d="M636 56 L634 74 L622 62 Z" fill="#e03131"/>
  <path d="M546 108 H628" stroke="#e03131" stroke-width="2.5"/>
  <path d="M628 100 L644 108 L628 116 Z" fill="#e03131"/>
  <path d="M546 108 L632 156" stroke="#e03131" stroke-width="2.5"/>
  <path d="M636 162 L622 156 L634 144 Z" fill="#e03131"/>
  <rect x="650" y="14" width="240" height="44" rx="8" fill="#fdeaea"/>
  <text x="770" y="42" text-anchor="middle" font-size="15" fill="#b02525" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">gpu-lab-01</text>
  <rect x="650" y="86" width="240" height="44" rx="8" fill="#fdeaea"/>
  <text x="770" y="114" text-anchor="middle" font-size="15" fill="#b02525" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">prod-deploy</text>
  <rect x="650" y="158" width="240" height="44" rx="8" fill="#fdeaea"/>
  <text x="770" y="186" text-anchor="middle" font-size="15" fill="#b02525" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">client-backup</text>
</svg>

</div>

<div class="big">

The boundary held perfectly. The **credential was never behind it**.

</div>

---

# "But I told it not to"

`CLAUDE.md` · `AGENTS.md` · a system prompt · *"never push, never force"*

All of it is **text in a context window** — competing with the task, forty thousand tokens of your code, and an hour of its own reasoning.

- A rule the agent can read is a rule it can **reason past**
- Sometimes it does not even do that — it just **forgets**

<div class="big">

Instructions are a **preference**. They are not a boundary.

</div>

---

# So don't ask. Remove

An instruction has to win the argument **every single time**.
A missing key wins **by default** — there is nothing to argue with.

<div class="fig">

<svg viewBox="0 0 900 230" width="860">
  <rect x="8" y="14" width="390" height="202" rx="14" fill="#ffffff" stroke="#c7cbd6" stroke-width="2"/>
  <text x="203" y="44" text-anchor="middle" font-size="13" font-weight="700" fill="#6b7280" letter-spacing="2">WHAT THE AGENT CAN REACH TODAY</text>
  <rect x="28" y="60" width="112" height="30" rx="8" fill="#fdeaea"/>
  <text x="84" y="80" text-anchor="middle" font-size="14" fill="#b02525">~/.ssh keys</text>
  <rect x="150" y="60" width="86" height="30" rx="8" fill="#fdeaea"/>
  <text x="193" y="80" text-anchor="middle" font-size="14" fill="#b02525">~/.aws</text>
  <rect x="246" y="60" width="98" height="30" rx="8" fill="#fdeaea"/>
  <text x="295" y="80" text-anchor="middle" font-size="14" fill="#b02525">gh login</text>
  <rect x="28" y="102" width="122" height="30" rx="8" fill="#eceef3"/>
  <text x="89" y="122" text-anchor="middle" font-size="14" fill="#1a1d23">other repos</text>
  <rect x="160" y="102" width="128" height="30" rx="8" fill="#eceef3"/>
  <text x="224" y="122" text-anchor="middle" font-size="14" fill="#1a1d23">shell history</text>
  <rect x="298" y="102" width="86" height="30" rx="8" fill="#eceef3"/>
  <text x="341" y="122" text-anchor="middle" font-size="14" fill="#1a1d23">cookies</text>
  <rect x="28" y="144" width="128" height="30" rx="8" fill="#4c5fd7"/>
  <text x="92" y="164" text-anchor="middle" font-size="14" fill="#ffffff" font-weight="600">your project</text>
  <rect x="166" y="144" width="160" height="30" rx="8" fill="#fdeaea"/>
  <text x="246" y="164" text-anchor="middle" font-size="14" fill="#b02525">project B's .env</text>
  <path d="M420 115 H528" stroke="#4c5fd7" stroke-width="4" fill="none"/>
  <path d="M528 103 L552 115 L528 127 Z" fill="#4c5fd7"/>
  <text x="486" y="96" text-anchor="middle" font-size="14" fill="#6b7280" font-style="italic">remove</text>
  <rect x="576" y="55" width="280" height="120" rx="14" fill="#ffffff" stroke="#4c5fd7" stroke-width="2.5"/>
  <text x="716" y="90" text-anchor="middle" font-size="13" font-weight="700" fill="#6b7280" letter-spacing="2">THE SANDBOX</text>
  <rect x="652" y="108" width="128" height="30" rx="8" fill="#4c5fd7"/>
  <text x="716" y="128" text-anchor="middle" font-size="14" fill="#ffffff" font-weight="600">your project</text>
</svg>

</div>

A sandbox is **capability removal**, not instruction. The agent is not told no. It simply lives in a **smaller world**.

---

# The same box. Nothing handed over

<div class="fig">

<svg viewBox="0 0 900 300" width="840">
  <rect x="10" y="30" width="230" height="240" rx="12" fill="#ffffff" stroke="#c7cbd6" stroke-width="2"/>
  <text x="125" y="58" text-anchor="middle" font-size="13" font-weight="700" fill="#6b7280" letter-spacing="2">YOUR MACHINE</text>
  <rect x="30" y="76" width="180" height="28" rx="7" fill="#fdeaea"/>
  <text x="120" y="95" text-anchor="middle" font-size="12.5" fill="#b02525" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">ssh-agent</text>
  <rect x="30" y="112" width="180" height="28" rx="7" fill="#fdeaea"/>
  <text x="120" y="131" text-anchor="middle" font-size="12.5" fill="#b02525" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">gh token</text>
  <rect x="30" y="148" width="180" height="28" rx="7" fill="#fdeaea"/>
  <text x="120" y="167" text-anchor="middle" font-size="12.5" fill="#b02525" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">docker daemon</text>
  <rect x="30" y="184" width="180" height="28" rx="7" fill="#fdeaea"/>
  <text x="120" y="203" text-anchor="middle" font-size="12.5" fill="#b02525" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">~/.gitconfig</text>
  <rect x="30" y="220" width="180" height="28" rx="7" fill="#eceef3"/>
  <text x="120" y="239" text-anchor="middle" font-size="12.5" fill="#1a1d23" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">other repos</text>

  <rect x="248" y="74" width="124" height="30" rx="8" fill="#eceef3"/>
  <text x="310" y="94" text-anchor="middle" font-size="11.5" fill="#9aa0ac" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">SSH_AUTH_SOCK</text>
  <rect x="248" y="116" width="124" height="30" rx="8" fill="#eceef3"/>
  <text x="310" y="136" text-anchor="middle" font-size="11.5" fill="#9aa0ac">git credentials</text>
  <rect x="248" y="158" width="124" height="30" rx="8" fill="#eceef3"/>
  <text x="310" y="178" text-anchor="middle" font-size="11.5" fill="#9aa0ac" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">docker.sock</text>
  <rect x="248" y="200" width="124" height="30" rx="8" fill="#eceef3"/>
  <text x="310" y="220" text-anchor="middle" font-size="11.5" fill="#9aa0ac">dotfiles</text>

  <rect x="368" y="8" width="26" height="284" rx="5" fill="#4c5fd7"/>
  <text transform="translate(352,150) rotate(-90)" text-anchor="middle" font-size="12" font-weight="700" fill="#4c5fd7" letter-spacing="2">NOTHING CROSSES</text>

  <rect x="520" y="30" width="370" height="240" rx="12" fill="#ffffff" stroke="#4c5fd7" stroke-width="2.5"/>
  <text x="705" y="58" text-anchor="middle" font-size="13" font-weight="700" fill="#4c5fd7" letter-spacing="2">THE SANDBOX</text>
  <rect x="610" y="96" width="190" height="46" rx="8" fill="#4c5fd7"/>
  <text x="705" y="126" text-anchor="middle" font-size="16" fill="#ffffff" font-weight="600" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">/workspace</text>
  <rect x="610" y="156" width="190" height="46" rx="8" fill="#ffffff" stroke="#c7cbd6" stroke-width="2"/>
  <text x="705" y="186" text-anchor="middle" font-size="16" fill="#1a1d23" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">a fresh ~</text>
  <text x="705" y="232" text-anchor="middle" font-size="14" fill="#6b7280" font-style="italic">that is the entire contents</text>
</svg>

</div>

---

# The intended workflow

<div class="big">

Same folder on disk. **Two worlds.**

</div>

<div class="fig">

<svg viewBox="0 0 900 300" width="820">
  <rect x="60" y="16" width="330" height="118" rx="12" fill="#ffffff" stroke="#c7cbd6" stroke-width="2"/>
  <text x="225" y="52" text-anchor="middle" font-size="19" font-weight="700" fill="#4c5fd7">You — on the host</text>
  <text x="225" y="82" text-anchor="middle" font-size="15" fill="#6b7280">VS Code · your keys · your identity</text>
  <text x="225" y="108" text-anchor="middle" font-size="15" fill="#6b7280">your push rights</text>
  <rect x="510" y="16" width="330" height="118" rx="12" fill="#ffffff" stroke="#c7cbd6" stroke-width="2"/>
  <text x="675" y="52" text-anchor="middle" font-size="19" font-weight="700" fill="#4c5fd7">The agent — in the sandbox</text>
  <text x="675" y="82" text-anchor="middle" font-size="15" fill="#6b7280">no keys · no identity · empty home</text>
  <text x="675" y="108" text-anchor="middle" font-size="15" fill="#6b7280">no other projects</text>
  <path d="M260 140 L400 212" stroke="#6b7280" stroke-width="3" fill="none"/>
  <path d="M406 202 L418 222 L394 220 Z" fill="#6b7280"/>
  <path d="M640 140 L500 212" stroke="#6b7280" stroke-width="3" fill="none"/>
  <path d="M506 220 L482 222 L494 202 Z" fill="#6b7280"/>
  <path d="M330 232 h60 l14 -14 h60 l14 14 h92 a10 10 0 0 1 10 10 v40 a10 10 0 0 1 -10 10 h-240 a10 10 0 0 1 -10 -10 v-40 a10 10 0 0 1 10 -10 Z" fill="#eceef3" stroke="#c7cbd6" stroke-width="2"/>
  <text x="450" y="268" text-anchor="middle" font-size="17" font-weight="600" fill="#1a1d23" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">/workspace</text>
</svg>

</div>

You keep working exactly as you do now. The agent works beside you — on the same files, with a **fraction of your reach**.

---

# The human is the gate

<div class="fig">

<svg viewBox="0 0 900 140" width="840">
  <rect x="10" y="38" width="300" height="64" rx="10" fill="#ffffff" stroke="#c7cbd6" stroke-width="2"/>
  <text x="160" y="64" text-anchor="middle" font-size="16" font-weight="600" fill="#1a1d23">the agent</text>
  <text x="160" y="88" text-anchor="middle" font-size="14" fill="#6b7280">edits · installs · tests · commits</text>
  <path d="M318 70 H360" stroke="#6b7280" stroke-width="3"/>
  <path d="M360 60 L380 70 L360 80 Z" fill="#6b7280"/>
  <rect x="390" y="30" width="180" height="80" rx="10" fill="#4c5fd7"/>
  <text x="480" y="64" text-anchor="middle" font-size="17" font-weight="700" fill="#ffffff">you</text>
  <text x="480" y="90" text-anchor="middle" font-size="14" fill="#dfe3f9">review · push</text>
  <path d="M578 70 H620" stroke="#6b7280" stroke-width="3"/>
  <path d="M620 60 L640 70 L620 80 Z" fill="#6b7280"/>
  <rect x="650" y="38" width="240" height="64" rx="10" fill="#ffffff" stroke="#c7cbd6" stroke-width="2"/>
  <text x="770" y="76" text-anchor="middle" font-size="16" font-weight="600" fill="#1a1d23">the world</text>
</svg>

</div>

<div class="big">

The agent **commits**. You **push**.

</div>

- Every change that leaves the machine **passes a person** — by design
- Per-project homes: project A's agent **cannot read** project B's credentials

---

# Two ways to get the same boundary

<div class="cols">
<div>

## Roll your own

```bash
docker run --name proj1 -it \
  -v /path/to/proj1:/workspace ubuntu

docker start -ai proj1   # tomorrow
```

**The boundary is complete.** It is the `-v` line, and there is no second line that matters.

<div class="note">

What you own: installing the tooling by hand · nothing written down, so nothing to share or rebuild · files owned by `root` in your repo · the agent installed and logged in again per container · one container per project, on your discipline

**Never** `-v ~/.ssh:/root/.ssh` — a mount hands back everything the box just took away.

</div>

</div>
<div>

## Or take mine

```bash
dev up
```

**The same boundary**, with the convenience put back.

<div class="note">

A normal devcontainer — VS Code's standard, not a fork · dev tools via `mise`: the versions your project pins, cached across sandboxes · ports · the agent installed and logged in · a fresh home per project · `dev ls`, `dev rm`

</div>

</div>
</div>

<div class="big">

The boundary is the **mount line**. Everything else is **ergonomics**.

</div>

---

# How to get it

```bash
curl -fsSL https://raw.githubusercontent.com/langdal/devcontainer/main/install.sh | bash

cd ~/code/my-project
dev up                 # builds once, then attaches. Project lands at /workspace
dev agent add claude   # a one-way copy of the agent's own login — never a mount
```

<div class="big">

**github.com/langdal/devcontainer**

</div>

<div class="note">

Threat model in full: `SECURITY.md` · host check: `dev doctor` · and yes — that is `curl | bash`, in a talk about not running what you have not read. **Read it first**, or clone and run `./install.sh`.

</div>

---

# Demo

```bash
dev up                 # start or attach — your project lands at /workspace
dev agent add claude   # a one-way copy of the agent's own login

dev up --dind          # docker in docker: its own daemon, not the host's

dev ls                 # every sandbox and volume on this machine
dev rm                 # throw one away
```

---

# What this does not defend against

## It defends against: a rogue agent

Confused, over-eager, reaching for capability it was never meant to have. **That is the realistic failure**, and it is the one we just watched.

## It does **not** defend against: a deliberately malicious agent

If the model — or something injected into its context — actively *wants* your source out, it will get it out. **Anything reachable is reachable in both directions.**

<div class="note">

Also out of scope: a compromised base image · a container escape via kernel bug · secrets you deliberately hand it.

</div>

---

# Honest about the defaults

<div class="cols">
<div>

## The network is open

- Isolation protects your secrets — a **hostname allowlist does not**
- GitHub, npm, the model API are on every allowlist anyway
- Broken networking is the **#1 reason** sandboxes get abandoned

```bash
dev fw log       # what it reached
dev up --closed  # deny by default instead
```

</div>
<div>

## What it costs you

- No SSH agent inside — **you** push
- `mise` covers the dev tools; **system** packages need a trip to maintenance mode
- The first image build is slow. **Once.**
- Nested Docker needs a kernel setting on some Linux hosts
- One more thing in the loop to learn

</div>
</div>

<div class="big">

A fair trade: some friction, for never trusting an agent's judgement about your **credentials**.

</div>

---

# The ask

<div class="kicker">This is not a mandate</div>

Your project, your call, your responsibility.

1. **Know** — can you name, right now, what your agent can reach? Keys, identity, other repos, the network?
2. **Reduce** — take the credentials out of its reach. Any mechanism you like.
3. **Reuse** — if you would rather not build it: this exists, it is one command.

<div class="note">

All of these count: your agent's own sandbox mode · a credential-free devcontainer · `docker run -v "$(pwd)":/workspace` · a throwaway VM · a cloud sandbox · `dev up`

</div>

<div class="big">

Pick **any** of them. Just pick **something** before you switch on auto mode.

</div>

---

<!-- _class: lead -->

# Questions

<div class="note">

**Repo** — github.com/langdal/devcontainer
**Threat model, in full** — `SECURITY.md`
**Install** — `curl -fsSL https://raw.githubusercontent.com/langdal/devcontainer/main/install.sh | bash`

</div>
