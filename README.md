# Qwen3.8-Flash-Next Portable Interface (Strata NVFP4)

[繁體中文說明](README.zh-TW.md)

One-click deployment of Qwen3.8-Flash-Next (125B MoE; the default is ISTA-DASLab's GSQ-RCO IQ3_S quantization, and NVFP4 is also available) on a Windows PC with a single NVIDIA RTX GPU (16 GB or more) and 64 GB of RAM, with an OpenAI/Anthropic-compatible API. The inference engine is [strata-nvfp4](https://github.com/sergqwer/strata-nvfp4); this project provides the portable packaging, the startup flow and the API entry point.

**One-click start: whatever is missing is downloaded automatically, and if everything is already there it starts offline.** Everything is installed inside this folder; the only thing that cannot be made portable is the NVIDIA driver. This repository contains only the startup scripts (about 50 KB). The model and the engine are downloaded on first launch.

| Component | Location |
|---|---|
| One-click launcher | `START.bat` → `start_next.ps1` |
| Inference engine and model API | Strata (`strata-nvfp4\`, listens only on `127.0.0.1:8080`) |
| LAN entry point | `next_gateway.py` (`<LAN-IP>:8000` and `127.0.0.1:8000`, key check, requests forwarded unchanged) |
| Model | `Strata-data\` (about 90 GB by default, about 130 GB for NVFP4; downloaded automatically on first launch) |
| Python | `strata-nvfp4\.venv\Scripts\` (embedded Python, downloaded automatically on first launch) |

## One-click start

Put the whole folder on the PC that will run the model. **A pure-English path is recommended** (for example `D:\QwenNext`; native engines often do not support Chinese paths). Then double-click:

```text
START.bat
```

Every launch checks the following steps in order and fills in only what is missing:

| Step | Already present | Missing |
|---|---|---|
| 1. Strata source `strata-nvfp4\` | Skipped if the version matches; updated in place if `-Tag` differs (the model is kept) | Cloned with git if available, otherwise downloaded as a zip (pinned to `v0.2.0-beta-nvfp4.3`) |
| 2. Portable Python `strata-nvfp4\.venv\Scripts\` | Skipped | Downloads python.org embedded 3.12.10 and pip (no installer, no registry writes) |
| 3. Engine + model `Strata-data\` | Skipped (see `portable_state\installed.json`) | Handed to Strata's own downloader (about 90 GB by default; press START.bat again after an interruption to resume) |
| 4. Launch | Strata (`127.0.0.1:8080`) + gateway (`<LAN-IP>:8000`, `127.0.0.1:8000`) | |

- **Moving:** After installation you can move the whole folder to another drive or another PC. On the next launch the change of location is detected and the absolute paths in Strata's config files are rewritten automatically.
- **Changing parameters:** Changing the model family, the context size or vision re-runs the Strata install automatically; files already downloaded are kept. Changing the key does not require re-running the install.
- **Crashes:** If either Strata or the gateway exits, the other one is stopped too, and the window stays open so you can read the error.

Requirements: native Windows 10/11 (WSL2 is not supported), an NVIDIA RTX 20–50 series GPU with **16 GB or more** of VRAM (the launcher checks and stops if there is less), driver 580 or later, 64 GB or more of RAM, about 150 GB of disk space (NVMe), and a fixed 65536 MB page file (`START.bat -SetPageFile` can set it up; see "Page file" below).

Parameters are added after `START.bat` (see the next section, "Model settings", for the defaults):

```powershell
.\START.bat -ClientKey mykey                          # Recommended: a key is needed for LAN access
.\START.bat -Family qwen-nvfp4-gptq                   # Switch to NVFP4 (96 GB RAM or more recommended; installed automatically)
.\START.bat -Model IQ3_XXS -Context 32768             # Change the quantization size / context (installed automatically)
.\START.bat -CheckOnly                                # Only check the hardware and run Strata's --check (downloads about 30 MB of source and Python, not the model)
.\START.bat -SetPageFile                              # Set a fixed 64 GB page file (needs administrator rights; reboot afterwards)
.\setup_next.ps1                                      # Download only, do not start (for example to download first somewhere with a fast network)
.\START.bat -Reinstall                                # Force the install to run again and replace the old system venv with the portable Python
```

### Page file

Windows limits the total memory that all programs can commit to "RAM + page file". Strata's engine needs about 80 GiB in low-RAM mode (about 100 GiB in normal mode), of which about 30 GiB is counted by Windows on behalf of the GPU driver. A system-managed page file often cannot grow in time, so Strata asks for a **fixed 65536 MB**. If there is not enough, the engine shrinks the expert cache in VRAM and becomes noticeably slower; in the worst case it cannot start.

```powershell
.\START.bat -SetPageFile                 # Placed on the drive that holds the model folder; the system drive keeps its system-managed size
.\START.bat -SetPageFile -PageFileDrive E
.\set_pagefile.ps1 -DryRun               # Only show what would be written; change nothing
.\set_pagefile.ps1 -Restore              # Restore the settings from before the change
```

`-SetPageFile` will:

1. Show the Windows administrator confirmation.
2. Check the target drive: USB and traditional hard disks are rejected, and the free space must be sufficient.
3. Back up the current settings to `portable_state\`.
4. Write the new settings.

**The setting takes effect only after a reboot.** A model download in progress resumes on the next launch. Afterwards the launcher prints `Page file: 65536 MB fixed` at the start; if it is set but you have not rebooted yet, it reminds you to reboot first.

A fixed 64 GB page file only takes up space on that drive. It does not slow anything down in normal use; it is written to only when RAM is really insufficient.

Loading the model takes a few minutes; the model is usable only when `/health` returns 200 (it returns 503 while loading). The actual URLs are printed at startup, for example:

```text
-- API: http://192.168.1.50:8000/v1   readiness: http://192.168.1.50:8000/health
-- On this PC also: http://127.0.0.1:8000/v1
```

- Endpoints: `/v1/chat/completions`, `/v1/messages` (Anthropic format), `/v1/models` and `/health`. Whether `/v1/responses` works depends on whether Strata provides it; it has not been verified.
- The model name can be anything. For the API key, use the value of `-ClientKey` (or `local` if you did not set one).
- **The gateway binds to this PC's LAN IP and to `127.0.0.1`.** Other computers on the LAN connect through the LAN IP, and programs on this PC use `127.0.0.1`. Strata itself listens only on `127.0.0.1:8080`. **Always set `-ClientKey`.**
  - **How the LAN IP is found:** It is detected on every launch. The launcher takes the private IPv4 address (10.x, 172.16–31.x, 192.168.x) on the adapter that holds the default route. Virtual adapters such as VMware and WSL are not chosen and are not opened up; if DHCP gives you a new IP, restarting picks it up.
  - **Other options:** `-HostAddress 127.0.0.1` restricts access to this PC, `-HostAddress 192.168.1.50` selects a specific IP, and `-HostAddress 0.0.0.0` opens all adapters. If no LAN IP can be found, it falls back to this PC only and tells you so.
- If the LAN cannot connect, open TCP 8000 from an administrator PowerShell on a trusted network (first confirm with `Get-NetConnectionProfile` that the network profile is Private):

  ```powershell
  New-NetFirewallRule -DisplayName "Qwen Next API 8000" -Direction Inbound -Protocol TCP -LocalPort 8000 -Action Allow -Profile Private
  ```

```python
from openai import OpenAI
client = OpenAI(base_url="http://<LAN-IP>:8000/v1", api_key="local")   # On the same PC you can also use 127.0.0.1
print(client.chat.completions.create(model="Qwen3.8-Flash-Next",
      messages=[{"role": "user", "content": "Reply with only OK"}], max_tokens=2048).choices[0].message.content)
```

Sending an image (image input is enabled by default):

```python
import base64
image = base64.b64encode(open("photo.jpg", "rb").read()).decode()
answer = client.chat.completions.create(model="Qwen3.8-Flash-Next", max_tokens=2048, messages=[{
    "role": "user",
    "content": [
        {"type": "text", "text": "What is in this image?"},
        {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{image}"}},
    ],
}])
print(answer.choices[0].message.content)
```

### Using it with Codex

Codex only knows the context limits of its built-in models. For a custom model you have to tell it yourself; otherwise it will not compact the conversation automatically before the context is full, and as soon as a request exceeds 128K, Strata returns 400 (`request exceeds the context window`).

Add the following to `%USERPROFILE%\.codex\config.toml` **at the very top, before any `[...]` section**:

```toml
model_context_window = 131072
model_auto_compact_token_limit = 110000
```

This means: the model has 128K, the conversation is compacted automatically at 110K, and about 20K is left for reasoning, the answer and tool results. Restart Codex after changing it. If you change the size with `-Context`, change these two numbers to match.

## Model settings

The principle is to **follow the official Strata and Qwen settings, and have this package add only what portability and connectivity need**.

| Item | Setting | Source and reason |
|---|---|---|
| Model | `qwen` family, `IQ3_S` size (changeable with `-Family` and `-Model`) | ISTA-DASLab's GSQ-RCO quantization (3.5-bit). The download is 83.6 GB, plus about 5 GB of MTP draft layers fetched by Strata. It needs about 52 GiB of RAM at runtime and **fits entirely in 64 GB of RAM**, so there is no need to enter low-RAM mode and read experts from the SSD. Strata also lists it as the default for 64 GB machines, but asks that "other programs be kept to a minimum". See the table below for the accuracy/speed trade-off. |
| Context | **131072 (128K)** (changeable with `-Context`; `-Context 0` lets Strata decide from the VRAM) | For agent clients such as Codex, the system prompt plus tool definitions alone are very large, so 64K is exceeded quickly (Strata returns 400 rather than silently truncating). Strata recommends 64K for 16 GB cards. The cost of 128K is that the KV cache grows in VRAM as the conversation gets longer; short conversations are unaffected, while in very long conversations fewer experts fit on the GPU and speed drops slightly. See "Using it with Codex" above for the Codex settings. |
| Sampling defaults | Applied by Strata according to the model card, depending on whether thinking is on | When thinking, `temperature 1.0 / top_p 0.95 / top_k 20`, matching Qwen3.8-Flash-Next's official `generation_config.json`. They apply only to fields the request does not carry; values carried by the request take priority. A fixed sampling block that older Strata versions wrote into the config file would override this behavior, so the launcher removes it as described in Strata's upgrade notes. The gateway does not change any sampling field by default. |
| `fit_max_tokens` | `true` (added by this package) | By default Strata returns HTTP 400 when `max_tokens` exceeds the remaining context, and agent-style clients often send very large values. When enabled, the value is clamped to the remaining space, and the response's `finish_reason` is reported as `length` as usual. |
| `host` | Fixed to `127.0.0.1` (added by this package) | Strata itself is not exposed; the LAN always goes through the gateway and its key. |
| `api_key` | Written only if `-UpstreamKey` is set, otherwise removed | Re-applied on every launch, so changing the key does not require re-running the install. |
| Low-RAM mode | Decided automatically by Strata | Below about 92 GiB of RAM, some experts are read from disk. |
| Vision | `yes` (enabled by default) | Downloads an extra encoder of about 0.9 GB and lets Strata decide where to put it: with less than 24 GB of VRAM it goes on the **CPU**, using no VRAM so that all of the VRAM stays with the expert cache; each image takes about 2–6 seconds and about 1–2 GiB of RAM. The `images: on (encoder on the …)` line in the install output shows the actual location. `-Vision gpu` forces it onto the GPU (about 1.4 GB of VRAM) and `-Vision no` turns it off. |

Items marked "added by this package" are written into `strata-*.json` by `portable\strata_config.py` on every launch. They are written every time because Strata rewrites the fields it manages whenever setup is re-run.

### Selectable quantizations

The figures below are Strata README's official measurements on an RTX 5090, a Ryzen 9 9950X3D and 128 GB of RAM. "Match with Q8_0" is the token-by-token agreement rate against the highest-precision Q8_0 version. "RAM needed" is the PC RAM required to reach that speed.

| How to select | Match with Q8_0 | Speed | RAM at runtime | RAM needed |
|---|---|---|---|---|
| Default (`qwen` + `IQ3_S`) | 90.0% | 228 tok/s | 52 GiB | 64 GB |
| `-Model IQ3_XXS` | 87.3% | 239 tok/s | 45 GiB | 64 GB |
| `-Family qwen-nvfp4-gptq` | 93.6% | 177 tok/s | 69 GiB | 96 GB |
| `-Family qwen-nvidia-nvfp4` | 92.9% | 167 tok/s | 69 GiB | 96 GB |
| `-Family qwen-nvfp4-mix` | 95.0% | 91 tok/s | 105 GiB | 128 GB |

- **64 GB machines:** NVFP4 enters low-RAM mode. The speed given in Strata's documentation is about 115 tok/s, which on the same reference machine is roughly half of IQ3_S. So 64 GB machines use IQ3_S by default, and GPTQ NVFP4 is recommended from 96 GB up.
- **IQ3_S accuracy:** Its token-by-token agreement rate is 3.6 percentage points lower than GPTQ NVFP4. However, in the benchmarks published by ISTA-DASLab its average score is on par with the original BF16 model (100.3%–101.4%, within the margin of error).
- **Switching versions:** The files for that version are downloaded additionally and the old files are kept, so you can switch back at any time.

## Strict format output

Format problems with self-hosted model APIs usually come from the API layer, not from the temperature:

- Structured-output fields are not handled.
- The chat template differs from the model's official template.
- `max_tokens` is silently lowered, causing truncation.

What this package does:

- **Structured output is left to the engine.** `response_format` (including `json_schema`), `stop`, `seed`, `logit_bias`, `min_p`, penalties and similar fields are all forwarded unchanged. Strata's `serve/` includes a built-in structured-output module (`structured.py`).
- **Full schema validation.** Strata validates fields and types against the schema only if the `jsonschema` package is installed; otherwise it only checks that the output is a JSON object. Its own setup does not install this package, so the launcher adds it.
- **The chat template is handled by Strata.** It follows the reasoning wording of Qwen's official `chat_template.jinja`; the gateway does not build prompts itself.
- **Official sampling values.** Strata fills them in per family, and the gateway does not change any value the client sends (everything in `next_config.json` is `null`).
- **No truncation.** `max_tokens` is clamped only when it exceeds the remaining context (`fit_max_tokens`); there is no fixed cap.

**When the format is unstable, do not lower the temperature by feel; measure first.** After the model has loaded, run:

```powershell
python format_probe.py --temps 0.3,0.7,1.0 --trials 5 --verbose
```

It runs each of five formats several times ("plain JSON", "json_schema structured output", "reply with only OK", "exactly three lines" and "tool call") and prints the pass rate at each temperature together with the failure reasons (for example, `finish_reason=length` means the output was truncated, not that the format was wrong). Only if a low temperature is clearly better should you set `sampling.temperature` in `next_config.json` (it affects only requests that do not carry a temperature), or add `-TemperatureCap 0.6` at startup (which also lowers high temperatures that the client sends explicitly).

## Speed

Measured on an RTX 5070 Ti 16 GB, 64 GB RAM, i5-14600K, PCIe 5.0, NVMe, Windows 11, Strata v0.1.44.1-nvfp4.2, with Codex as the client.

| Item | Default IQ3_S | NVIDIA NVFP4 (`-Family qwen-nvidia-nvfp4`) |
|---|---|---|
| Memory mode | Fits entirely in RAM | Low-RAM mode (some experts read from the SSD) |
| Expert cache on the GPU | 4,028 experts (7.69 GiB) | 2,292 experts (5.90 GiB) |
| Model load time | about 2–3 minutes | about 1–2 minutes |
| Prompt reading | 60.8K tokens in about 40 seconds (first turn after the server starts, which reads the whole conversation history) | 23.9K tokens in about 49 seconds (first turn); afterwards only the new part is read each turn, about 17–20 seconds |
| Text generation | **36.8–45 tok/s** | 10.5–12 tok/s after warm-up |
| Expert cache hit rate | 80% | 54–63% |

The IQ3_S figures come from a single turn, measured in a 60K-token conversation while tools were being called. The NVFP4 figures are the result of about 10 consecutive turns.

### Compared with figures found online

Public measurements on a 16 GB GPU + 64 GB RAM (IQ3_S or similar quantizations):

| Source | System | Generation speed |
|---|---|---|
| Community tests in Strata issue #2453 | Linux, RTX 5070 Ti | 70–95 tok/s (short conversations) |
| note.com blog | Linux, RTX 5070 Ti, IQ3_XXS, 128K | 50–70 tok/s |
| note.com blog | Ubuntu, RTX 5070 Ti, Ryzen 5 9600X, 256K | 50–90 tok/s |
| Reporter in Strata issue #2453 | **Windows**, i9-14900K, RTX 5060 Ti 16 GB | 55–69 tok/s (short conversations) |

Keep the following in mind when comparing:

- **Conversation length:** The longer the conversation, the slower each token. Most figures online use short prompts; the 36.8–45 tok/s measured here was taken inside a 60K-token conversation.
- **Operating system:** Most public figures are from Linux. The Windows WDDM driver reserves part of the VRAM for the desktop, and locked memory is also limited.
- **CPU:** Experts that miss the cache are computed on the CPU. CPUs with AVX-512 (for example the Ryzen 7000/9000 series) are faster; consumer Intel CPUs from the 12th generation onward have only AVX2.
- **A fair comparison:** While the model is running, run the `BENCH.bat` that ships with Strata from `strata-nvfp4\`. In about 10 minutes it produces a shareable report, and only a comparison against other people's reports is meaningful.

### What you can do

- **Use a newer Strata (the default is already `v0.2.0-beta-nvfp4.3`).** Officially measured on an RTX 5090, generation speed was 203.3 vs 179.5 tok/s (5 interleaved runs, median +8%). The newer version also puts the vision encoder on the CPU when VRAM is below 24 GB, returning about 1.4 GB of VRAM to the expert cache; the CPU worker threads are now set by physical cores, and on hybrid-architecture CPUs it uses "performance cores + half of the efficiency cores".
- **Plug the monitor into the motherboard's display output.** With a CPU that has integrated graphics (for example the i5-14600K), the desktop can be handled by the integrated GPU, so the discrete GPU does not need to reserve VRAM for the desktop and can hold more experts.
- **On a 64 GB machine, use the default IQ3_S.** It fits entirely in RAM and does not need low-RAM mode; the points below mainly concern NVFP4.
- **The first requests are the slowest.** With NVFP4 on a 64 GB machine, low-RAM mode is used: most experts are read from the SSD the first time they are needed and then kept in RAM by Windows, and the GPU's expert cache also adapts automatically to the experts actually used. After a few more requests, both speed and hit rate go up.
- **Close other programs (especially browsers) while the model runs.** In low-RAM mode, the number of experts that can stay in RAM is "available RAM minus 6 GiB", and any RAM taken by other programs turns into SSD reads.
- **Agent-style clients (such as Codex) are especially slow on the first turn.** Every time they send a system prompt and tool definitions of tens of thousands of tokens. Strata records a checkpoint at the end of each turn, so the next turn of the same conversation reads only the new tokens, and only the first turn pays the full reading time.
- **Use `-Vision no` when you do not need image input.** The vision encoder takes about 1.4 GB of VRAM on the GPU and 1–2 GiB of RAM on the CPU; turning it off gives that space back to the experts.
- **Adding RAM helps the most.** From 92 GiB up, all experts stay resident in RAM and the SSD is no longer read.

## Differences from the deployment guide circulating online

A Chinese-language guide circulating online recommends a "NVIDIA ModelOpt NVFP4 + strata-nvfp4" setup. Qwen3.8-Flash-Next and `sergqwer/strata-nvfp4` are both real, but the commands in the guide are not: `python -m strata.serve`, `--adapt-async` as a standalone command, `--offload-device cpu`, `--gpu-memory-utilization`, `STRATA_PIN_BY_NEED` and `pip install -r requirements.txt` cannot be found in Strata's README or setup.py. The actual flow is `START-HERE.bat` (setup.py) → `serve/server.py --engine strata --config …`, and this package follows that. In addition, no evidence was found for "near-lossless": Strata's README only gives a top-token agreement rate against Q8_0 of 93.6% for the GPTQ version (measured on an RTX 5090 / 128 GB), and there is no corresponding figure for the NVIDIA version. To compare, use `-Family qwen-nvfp4-gptq` and measure yourself with `format_probe.py`. A 16 GB GPU with 64 GB of RAM runs in low-RAM mode (some experts are read from disk), so treat measured speed as the reference; the 40–55 tok/s in the guide has no cited source.

## How the portable Python works

Strata's `START-HERE.bat` runs `setup.py` with `.venv\Scripts\python.exe` whenever that file exists. `setup.py` installs packages only with `sys.executable -m pip install` and does not check whether it is a venv. So this package puts an **embedded Python** at that location: Strata's flow is completely unchanged, but neither winget nor a system Python is needed.

The `._pth` file of embedded Python prevents scripts from finding modules in their own folder. This was confirmed by testing locally: without handling it, `tools\*.py` and `serve\server.py` fail with `ModuleNotFoundError`. `portable\sitecustomize.py` restores that behavior, and after adding it all three kinds of scripts were tested and work.

## Verified and unverified

**Tested on a Windows 11 machine without a GPU using a fake Strata** (a fake setup.py, a fake server.py, and the system Python standing in for the portable Python):

- First install and the skip on the second run. Changing the family or context re-runs setup; changing the key does not re-run it but does write the config file.
- `--context` is not passed when no context is specified; the config file name that setup actually writes is recorded rather than guessed from the file name.
- The config file's `host`, `fit_max_tokens` and `api_key` are applied, and Strata's own `sampling` is left untouched.
- After startup, a request through the gateway reaches Strata with its content unchanged (including `response_format` and an oversized `max_tokens`), and the client key check works.
- When Strata crashes, the gateway is shut down with it and the error code is returned, with no leftover processes afterwards.
- After moving to a path containing spaces and Chinese characters, the absolute paths in the config file are rewritten automatically (case-insensitively).
- `next_gateway.py`: unchanged forwarding by default, the optional value filling and temperature cap, SSE forwarded chunk by chunk, and 502 when the upstream is unreachable.
- The decision logic of `format_probe.py`.
- `set_pagefile.ps1 -DryRun`:
  - Computing the new settings: converting from automatic management, keeping other drives, replacing an existing setting, and setting it on the system drive itself.
  - Not rewriting when already set, drive not found, insufficient space, and restoring the backup.
  - Recognizing the drive type (NVMe / SSD).

**Confirmed on real hardware (RTX 5070 Ti, 64 GB RAM):**

- **Install:** The portable Python and pip, all setup.py parameters being accepted without stopping to ask questions, and the git clone route.
- **Download:** The engine, the model and the vision encoder all finished downloading and passed SHA-256 verification.
- **Page file:** After setting it to a fixed 65536 MB and rebooting, the launcher's check shows `65536 MB fixed` and Strata's warning is gone.
- **Running (Strata v0.1.44.1-nvfp4.2):** Both IQ3_S and NVIDIA NVFP4 load; reasoning and tool calls through the gateway using `/v1/responses` work, and Strata applied the official sampling defaults.
- **Exceeding the context:** Strata returns 400 rather than truncating; this is why the default is 128K and why the compaction settings are spelled out in "Using it with Codex".

**Not verified (not yet run on real hardware with a GPU; reports are welcome):**

- The upgrade, install and speed of the default Strata `v0.2.0-beta-nvfp4.3` on real hardware. It has been checked against its source code that the install parameters the launcher uses are all still there, and that the server still starts with `serve/server.py --engine strata --config … --port …`.
- Actually sending an image to the model for reading.
- The launcher's automatic installation of `jsonschema`, and the resulting full `json_schema` validation.
- `set_pagefile.ps1` actually writing to the registry: the format written is the same as the Windows "Virtual Memory" dialog, but only the dry run has been tested.
- Whether the way Strata picks its engine version depends on git information when the source is obtained as a zip (rather than with git). Machines with git installed use git clone and are not affected.

## Troubleshooting

- **Every reply is `!`**: The Strata README has a dedicated section on this; it is usually related to RAM / the page file or the driver, so follow that section.
- **Startup is unresponsive for a long time**: The first load and low-RAM mode are both slow. Watch the Strata window output; `/health` returning 503 is normal.
- **Download interrupted**: Press `START.bat` again. Completed steps are skipped and the model download resumes.
- **Changing the Strata version**: `.\START.bat -Tag <version tag>`. The launcher remembers the installed version and updates in place when the tag differs: a git install is switched with git, while a zip install is replaced by a new version folder, the portable Python is kept, and the old folder is renamed and left in place. Then the Strata install runs once more to update the engine (about 0.5 GB). The model is in `Strata-data\` and is not downloaded again.
- **Linux**: Strata supports Linux (`./setup.sh`), but this package's launcher is written for Windows only.

## License

This repository's scripts are released under the [MIT License](LICENSE). The components downloaded on first launch are **not covered by this license** and are used under their own original licenses:

- [strata-nvfp4](https://github.com/sergqwer/strata-nvfp4): MIT.
- Python (the embedded build from python.org): PSF License.
- Model weights: under the license on each model's Hugging Face page. The Strata README notes that the license of `qwen-nvidia-nvfp4` prohibits removing the safety restrictions.
