# Changelog

## [2.0.1](https://github.com/langdal/devcontainer/compare/v2.0.0...v2.0.1) (2026-08-17)


### Bug Fixes

* tty lacked LC_LANG settings ([0f5213c](https://github.com/langdal/devcontainer/commit/0f5213c9af54df7e5ff47ffd3d78f99f4b2f9a26))
* tty lacked LC_LANG settings ([2f34d59](https://github.com/langdal/devcontainer/commit/2f34d59eb3a33766047b53dafe8229c6ce26cb18))

## [2.0.0](https://github.com/langdal/devcontainer/compare/v1.7.0...v2.0.0) (2026-08-16)


### ⚠ BREAKING CHANGES

* **cli:** 'dev scaffold' and the generated .devcontainer/ flow are removed; use 'dev up' / editor-agnostic attach instead.
* **cli:** 'dev' (bare) now prints usage; start with 'dev up', run commands with 'dev exec' -- CMD [ARGS...]. 'fw disable/enable' are 'fw off/on'; cold-start-with-firewall-open is 'dev up --open'. The old --flag aliases (--disable-firewall, --enable-firewall, --monitor, --monitor-fw, --reset, --self-update, --create-dev-container) are removed.

### Features

* **cli:** add advisory host checks ([3244eae](https://github.com/langdal/devcontainer/commit/3244eae6be690d5bda0855952457d9d369473975))
* **cli:** add down and status verbs ([67fd36f](https://github.com/langdal/devcontainer/commit/67fd36f61a35f08f0a33b03356615f1eb8d75e51))
* **cli:** add fw off/on actions and unknown-verb rejection ([589fecd](https://github.com/langdal/devcontainer/commit/589fecd875ae9afa0039baef045b74d51b3fee9b))
* **cli:** add nested-mode host checks, migrating preflight probes ([1935d15](https://github.com/langdal/devcontainer/commit/1935d15a288cee7cbcb0d3f97fc8cf7869b4f605))
* **cli:** add overridable host probes for the check registry ([7150b45](https://github.com/langdal/devcontainer/commit/7150b458defb73116681b424f042b101d70a0289))
* **cli:** add phase-0 and blocking host checks ([7317a6f](https://github.com/langdal/devcontainer/commit/7317a6faf146d0f5e39b0d85336cf251833d0951))
* **cli:** add shell verb (attach-only, never creates) ([07cbb3c](https://github.com/langdal/devcontainer/commit/07cbb3c34847f15952a01747019dac393674a0c0))
* **cli:** add the dev doctor verb ([c049524](https://github.com/langdal/devcontainer/commit/c049524fbee5314e2f92638916ae8cd50f640a2f))
* **cli:** add the host-check registry, filter and runner ([7bbdfe1](https://github.com/langdal/devcontainer/commit/7bbdfe1b55f666e324ff1539b7013bf70defb044))
* **cli:** add up/exec verbs as shims over the start path ([04fb375](https://github.com/langdal/devcontainer/commit/04fb37510b4faff2067b1d45b9bba3687dcb34a3))
* **cli:** hint restart after allowlist approval on a running container (I7) ([d448a5d](https://github.com/langdal/devcontainer/commit/d448a5d8800e551bbf47b24ca6b25efd00dce452))
* **cli:** open egress by default; --closed opt-in, DEV_EGRESS default, fw open/close ([f7a53e1](https://github.com/langdal/devcontainer/commit/f7a53e1ed59d69c84c3fe535ed53a3a60737e4ef))
* **cli:** remove deprecated flag aliases and legacy start spellings ([f689f79](https://github.com/langdal/devcontainer/commit/f689f790ee053700a6bc75c23111b312d285bce2))
* **cli:** remove scaffold subcommand ([b150652](https://github.com/langdal/devcontainer/commit/b15065218a739ac8c59c27d11d54f38d380a334d))
* **dev:** scope-guard ambient GITHUB_TOKEN, add DEV_GITHUB_TOKEN opt-in ([40f818f](https://github.com/langdal/devcontainer/commit/40f818f609b4f927fbcb4c810c0e0702aa5aa12a))
* **dev:** scope-guard ambient GITHUB_TOKEN, add DEV_GITHUB_TOKEN opt-in ([6058d5f](https://github.com/langdal/devcontainer/commit/6058d5f3ecd205cc3a7725ab00131c38fceae211))
* **firewall:** extend default allowlist to cover mainstream dev workflows ([e7d4720](https://github.com/langdal/devcontainer/commit/e7d47206096fbff1325465b1d6b17a13616ee2a6))
* **firewall:** open/closed egress modes; open keeps link-local blocked and connections logged ([406d058](https://github.com/langdal/devcontainer/commit/406d058928a719816e75ea1135b2de4fae341c73))


### Bug Fixes

* **ci:** repair the three jobs that failed on their first real run ([bc88c49](https://github.com/langdal/devcontainer/commit/bc88c49c224b767718d0ad4b5a4ab045d613faf7))
* **cli:** clear the small findings left over from both increments ([531a13f](https://github.com/langdal/devcontainer/commit/531a13ff8cb87059fc8945d3a49fc367444032f7))
* **cli:** close last two fail-open probes and fix dry-run podman-machine block ([323f809](https://github.com/langdal/devcontainer/commit/323f809508bea758ca11ea59af8b1fcabc0e0133))
* **cli:** close whole-branch review findings in the verb surface ([b46812f](https://github.com/langdal/devcontainer/commit/b46812f33f7f8c7ad01a3ee7853e016aae917b18))
* **cli:** correct disk-space/engine-cli-match probes, drop home-volume-owner ([223eead](https://github.com/langdal/devcontainer/commit/223eead0defd7a9b745f84448e3ef2861106b75d))
* **cli:** detect podman engine behind a docker CLI, not from the binary ([18fd483](https://github.com/langdal/devcontainer/commit/18fd483de3407f5e5619f8a740a00a3686e2365d))
* **cli:** gate the podman-machine check on operations that need an engine ([f04cc55](https://github.com/langdal/devcontainer/commit/f04cc55eb787672eddb0c1cfdc4a61c9e00c3fa9))
* **cli:** gate the two ensure_runtime_ready call sites the brief missed ([1b8a946](https://github.com/langdal/devcontainer/commit/1b8a94656eef381f50e672f9d538cf550b3fa80c))
* **cli:** guard status probe against vanished containers and probe failure ([f72fb68](https://github.com/langdal/devcontainer/commit/f72fb68c1740458352035f845b354c3e8c5b7379))
* **cli:** keep dev doctor reporting on hosts detect_runtime refuses ([f71eb33](https://github.com/langdal/devcontainer/commit/f71eb3388f7839ef47e1446d34b6c8c9c6e47f45))
* **cli:** keep the DEV_RUNTIME diagnostic's established wording ([daeccfc](https://github.com/langdal/devcontainer/commit/daeccfc5103b23b8cc475033edc62a220cbacc0f))
* **cli:** make doctor's header and CLI-mismatch check report reality ([d3d37ae](https://github.com/langdal/devcontainer/commit/d3d37ae6bc9771cb8cfb0290664ae0c671dbf77b))
* **cli:** only inject firewall proxy env in closed mode (attach + nested engines) ([87e6b8d](https://github.com/langdal/devcontainer/commit/87e6b8d814ef0f427f6abd9be48d4593d9214a57))
* **cli:** pin runtime version in hyphen-mapping test guard ([58093af](https://github.com/langdal/devcontainer/commit/58093afdd5fac18de38d09daa9ebad0d5e496bcd))
* **cli:** replace buildx's block-if-building severity with block-in-doctor ([f173eae](https://github.com/langdal/devcontainer/commit/f173eaea0a9a0c0e140fddd3345ef8e54f5b2367))
* **cli:** restore preflight remediation text and widen subid-grant scope ([c180139](https://github.com/langdal/devcontainer/commit/c1801390888785a377d330a0f2a0b2e87ce896f2))
* **cli:** stop run_check aborting dev under set -e on a failing probe ([e798b46](https://github.com/langdal/devcontainer/commit/e798b46f216365b251a8b7e52d71f9b53fee575b))
* **cli:** two defects found by the first real macOS run ([56f8273](https://github.com/langdal/devcontainer/commit/56f8273849d5c7dabb2d8e79e1494c099ee50219))
* **cli:** verb-spelling error messages and exec empty-command guard ([5e0a1a6](https://github.com/langdal/devcontainer/commit/5e0a1a6f1fd94a947232a44c184e813c9e4fc3e8))
* **entrypoint:** proxy Maven https downloads, explain the maintenance gap ([8bb5117](https://github.com/langdal/devcontainer/commit/8bb5117474ba1ee99118a4d60a0c2e78ac8de9a8))
* **firewall:** capture open-mode DNS via NFLOG so fw log works without CAP_NET_RAW ([8f24460](https://github.com/langdal/devcontainer/commit/8f24460c3d5a2f28d3de6ad8861eaee32ff6b659))
* **firewall:** close IPv6 egress bypass and harden startup portability ([ba3d2d4](https://github.com/langdal/devcontainer/commit/ba3d2d4b83441e22371a5d3d79a3b7658bcef861))
* **firewall:** make fw close re-confine open containers; harden metadata block, DNS, JVM-seed, and toggle tests ([134f6c6](https://github.com/langdal/devcontainer/commit/134f6c61fb43326c0307debc190a6995156e48f2))
* **firewall:** validate allowlist entries before building the filter (C1) ([c8b4cd5](https://github.com/langdal/devcontainer/commit/c8b4cd5cd9debe7ff06f5d3dc635186859d87ac7))
* **lint:** correct hadolint asset URL and close the rule's blind spot ([2a47b25](https://github.com/langdal/devcontainer/commit/2a47b253a3c698cd700b86984e9af7d14bb281bf))
* **lint:** silence SC2034 for shell.sh's cross-file globals ([08daf9e](https://github.com/langdal/devcontainer/commit/08daf9e4b14dec3afd94bc29046066571cc08c4c))
* **lint:** verify tool downloads on every platform, fail closed ([7f35bd1](https://github.com/langdal/devcontainer/commit/7f35bd1bea8bc9c45bbaf97ed9ac84f05795c457))
* **test,docs:** make scenario 52 DNS check assert, correct SECURITY.md rule order ([7e2a4e0](https://github.com/langdal/devcontainer/commit/7e2a4e03868bd49fc2e7c73840ba6f0faa206f51))
* **test:** close the final-review findings ([e638fd2](https://github.com/langdal/devcontainer/commit/e638fd209adb471a0f5722de1ca8c76c0e478b44))
* **test:** make runtime tests platform-independent; record probe findings ([94e7618](https://github.com/langdal/devcontainer/commit/94e7618df0a51f699cd8347a0c7c657eaaf482a8))
* **test:** make the harness run on macOS's bash 3.2 ([c581387](https://github.com/langdal/devcontainer/commit/c58138762a9807f40ab8da1a63a9dd7eb19509b5))
* **test:** migrate scenario 21 fw off/on to open/close (matrix-caught) ([c16fb67](https://github.com/langdal/devcontainer/commit/c16fb67ee12f2caf7fc1696b2b6e1633b79429c1))
* **test:** nested-egress probes assert the inner result, not outer-exec failure (C4) ([31b761d](https://github.com/langdal/devcontainer/commit/31b761d35dbc3322eae063e127af04bc1e4bf626))
* **test:** pin closed-mode scenarios to --closed; make fw log/drops work headless ([71ff9de](https://github.com/langdal/devcontainer/commit/71ff9debe3f7a51dc7d5d148187eaa76f3b1658b))
* **test:** pin scenario 26 to closed egress mode ([3b1190b](https://github.com/langdal/devcontainer/commit/3b1190b40dcd4b03f06e9f135ebbcd01e0c5ead6))
* **test:** use $RUNTIME instead of hardcoded docker in host-side scenario probes ([378402c](https://github.com/langdal/devcontainer/commit/378402c85ca8cedc3b07121f445476cccd70fd38))
* **update:** ignore prerelease tags in dev update, matching install.sh ([eee47ec](https://github.com/langdal/devcontainer/commit/eee47ecf301a7e2c4c328778b749ac2cd54540a4))
* **volumes:** keep-id migrate devcontainer-pind like devcontainer-dind (I1) ([f51e58e](https://github.com/langdal/devcontainer/commit/f51e58e3016942ee5b2a1094ff3175aa30a07f00))

## [1.7.0](https://github.com/langdal/devcontainer/compare/v1.6.2...v1.7.0) (2026-07-08)


### Features

* **agent:** auto-detect running dind/pind container's storage ([ee7affe](https://github.com/langdal/devcontainer/commit/ee7affe5f2c2fbde35ced0f40df56b719d57a55c))
* **dotfile:** add `dev dotfile add/rm` for arbitrary host files ([5056400](https://github.com/langdal/devcontainer/commit/5056400eab26b039b1b236d47656b88152113234))


### Bug Fixes

* **agent:** read Claude credentials from macOS Keychain when file absent ([a7b73e1](https://github.com/langdal/devcontainer/commit/a7b73e1a9453463e6035e74b207c52e05f67e48b))
* **agent:** route dev agent at dind/pind storage ([5b44659](https://github.com/langdal/devcontainer/commit/5b44659b08f1810a7b6dca0efc32075d13303a58))
* **agent:** strip macOS xattrs when taring host creds ([2ccd731](https://github.com/langdal/devcontainer/commit/2ccd7317ca18a7aef674683cbd8a3149bab7e4e5))
* **agent:** validate args before resolving storage ([0f5303a](https://github.com/langdal/devcontainer/commit/0f5303acb186d638506300fd939dbfd5ff229b5b))
* **dind,pind:** chown ~/.local/share to vscode so agent injection can write ([6c54fe3](https://github.com/langdal/devcontainer/commit/6c54fe341e6f30258b95107c1ade70a0d9d7255c))
* **reset:** clean rootful dind/pind home+mise volumes on macOS+podman ([9d8a4dd](https://github.com/langdal/devcontainer/commit/9d8a4dd65319b951df20077a35dfdac6bf19449a))

## [1.6.2](https://github.com/langdal/devcontainer/compare/v1.6.1...v1.6.2) (2026-07-08)


### Bug Fixes

* **pind:** add amd to allow list ([d289fec](https://github.com/langdal/devcontainer/commit/d289fecae2ab1dee1552a2478ec258b9309252c6))
* **pind:** add amd to allow list ([9c8bc08](https://github.com/langdal/devcontainer/commit/9c8bc0897a41faf82d1666dd1fa5847027426dc6))

## [1.6.1](https://github.com/langdal/devcontainer/compare/v1.6.0...v1.6.1) (2026-07-08)


### Bug Fixes

* **agent:** skip initialization of claude ([246b13f](https://github.com/langdal/devcontainer/commit/246b13f26eeed010e3bb9c173c4478786c06e585))
* **agent:** skip initialization of claude ([88bcf47](https://github.com/langdal/devcontainer/commit/88bcf47f6a948c2b1fbfd430a42f206d6db68d55))

## [1.6.0](https://github.com/langdal/devcontainer/compare/v1.5.1...v1.6.0) (2026-07-07)


### Features

* add pind Dockerfile target with rootless podman ([d70274e](https://github.com/langdal/devcontainer/commit/d70274ec2a9606c3aad12cc017e869571c9c3933))
* add podman-docker shim and docker-compose symlink to pind image ([9da15dd](https://github.com/langdal/devcontainer/commit/9da15dd33ced61c96270ef81866cc33c01ee02f8))
* **agent:** add dev agent subcommand skeleton and router wiring ([fc6e333](https://github.com/langdal/devcontainer/commit/fc6e333d819684966d87eeecb7e033a7efcf7dd9))
* **agent:** add manifests, source resolution, and add --dry-run ([2382ee8](https://github.com/langdal/devcontainer/commit/2382ee8aeda4e608b44073604c27931913058311))
* **agent:** copy curated files into the home volume via keep-id helper ([f1b0e29](https://github.com/langdal/devcontainer/commit/f1b0e2945f57b0cff896e7123568d6636aabef93))
* **agent:** implement dev agent list and rm ([4706f46](https://github.com/langdal/devcontainer/commit/4706f46fe2972f32e80d520656c1b8bd412fbdad))
* apply apparmor and subid preflights to pind mode ([c650e18](https://github.com/langdal/devcontainer/commit/c650e182ab487d42da2f844d31f9b12de885cd08))
* implement pind-init.sh podman engine setup ([31cd941](https://github.com/langdal/devcontainer/commit/31cd941d82bb805d245f3189ca854a30e3b583e8))
* merge registry allowlist for pind mode ([1b6c071](https://github.com/langdal/devcontainer/commit/1b6c071ada0368141e13faba0f8406640b5cb7f4))
* route pind mode in entrypoint ([37de7ea](https://github.com/langdal/devcontainer/commit/37de7eac7e6afae95564f3a5a0a2a6effe079607))
* scaffold pind .devcontainer via dev scaffold --pind ([9532c3d](https://github.com/langdal/devcontainer/commit/9532c3dd47bb989ec0de8fd05a0273c8afd10767))
* wire --pind flag, container, volume, and mutex into dev ([715a77f](https://github.com/langdal/devcontainer/commit/715a77f178c90ab2ad1856e52c2243b0ce04e8b4))


### Bug Fixes

* **agent:** apply --userns=keep-id to list/rm helpers ([8be6a57](https://github.com/langdal/devcontainer/commit/8be6a571ada8d7eacaa71fc52532820bcefb2e47))
* **agent:** make home-volume creation idempotent on podman ([54f2c75](https://github.com/langdal/devcontainer/commit/54f2c7586dc0804b9c9ed73bc0b497087ee52c00))
* **agent:** preflight base image and cover broken-symlink path ([bcc0a56](https://github.com/langdal/devcontainer/commit/bcc0a56bf745ab60f933ff5b8d2d6173d717ccb2))
* **agent:** propagate _agent_expand exit through command substitution in rm ([5e4e4bc](https://github.com/langdal/devcontainer/commit/5e4e4bc909e8c11ae81d09d035aede49ffb16703))
* **agent:** set HOST_UID in agent dispatch and guard empty keepid_args ([ddd4123](https://github.com/langdal/devcontainer/commit/ddd4123265f4d1a00218306f05ca5b196f706794))
* enable slirp4netns allow_host_loopback so pind nested containers reach the proxy ([4ada939](https://github.com/langdal/devcontainer/commit/4ada9394260ee9083bb14eecbea433a457653a92))
* symmetric pind mutex/reset/fw resolution and pind polish ([44d0960](https://github.com/langdal/devcontainer/commit/44d09600a9c8c71b5ff11ec895f13fd66b7a4729))
* use default_rootless_network_cmd for slirp4netns pin in pind-init ([555599c](https://github.com/langdal/devcontainer/commit/555599c9f05b2daca29feab3a868e1307cc4a26e))

## [1.5.1](https://github.com/langdal/devcontainer/compare/v1.5.0...v1.5.1) (2026-07-04)


### Bug Fixes

* **dev:** bust buildah label cache on DEV_VERSION build-arg change ([2f38fb0](https://github.com/langdal/devcontainer/commit/2f38fb0e1ba3daae2c07ff79bada5c9ba14c3fec))
* **dev:** bust buildah label cache on DEV_VERSION build-arg change ([6d19dac](https://github.com/langdal/devcontainer/commit/6d19dac80acf02932ee8da691f1e044710e5951a))

## [1.5.0](https://github.com/langdal/devcontainer/compare/v1.4.0...v1.5.0) (2026-07-04)


### Features

* **dev:** surface unapproved allowlist as a likely mise-install cause ([12c49aa](https://github.com/langdal/devcontainer/commit/12c49aaf28a2aedd57877ab1cef6594a2abadf6f))


### Bug Fixes

* **dev:** recreate a stale non-keep-id container instead of reusing it ([2345432](https://github.com/langdal/devcontainer/commit/234543270ca9dc0671311e631f4ce1c326892478))
* **firewall:** allowlist Sigstore hosts for mise attestation verification ([8b36b69](https://github.com/langdal/devcontainer/commit/8b36b6983f4df6f783df20fd8b12f7a5c7669241))
* **shell:** activate mise for bash so JAVA_HOME and tool env are set ([71abbae](https://github.com/langdal/devcontainer/commit/71abbae35f3bed7beada1e569c2e277006ce82ef))

## [1.4.0](https://github.com/langdal/devcontainer/compare/v1.3.0...v1.4.0) (2026-07-03)


### Features

* **dev:** sandbox hardening — allowlist approval gate, GitHub-token guidance, firewall & dind hardening ([b6019b0](https://github.com/langdal/devcontainer/commit/b6019b0a1bf394fb1f4994eff7f89f698abca0b3))
* **dev:** subcommand CLI + module split and per-workspace home volume ([54be645](https://github.com/langdal/devcontainer/commit/54be645c698b4359e84e4efbf84526cc022cd9fe))


### Bug Fixes

* **build:** update ci image ([9d5ee41](https://github.com/langdal/devcontainer/commit/9d5ee4143fee68b0f1d87fabe78ec0bc342e4024))
* **dind:** add --userns=keep-id on rootless podman so vscode can write /workspace ([fc6a8fb](https://github.com/langdal/devcontainer/commit/fc6a8fb2ffadc4cdd37a05cefa4464ca061d9c2c))
* **dind:** preflight subuid grant instead of misdiagnosed kernel limit ([07a1f70](https://github.com/langdal/devcontainer/commit/07a1f70cb21e69b64f422c2e42c1038fb5f61e1c))
* **dind:** preflight subuid grant instead of misdiagnosed kernel limit ([af0864d](https://github.com/langdal/devcontainer/commit/af0864d6b95a00415a1f7382ffee74d73e793bca))
* **test:** forward GITHUB_TOKEN in scenario-local image builds to avoid anonymous GitHub rate limits ([9abdf72](https://github.com/langdal/devcontainer/commit/9abdf7275eaaff06bd911179bc6c2251678b2a0d))
* **test:** make scenario 22 git-identity seeding work in the CI VMs ([dc58a49](https://github.com/langdal/devcontainer/commit/dc58a49b609915358694e9b8d76c23a5f20b5b9d))

## [1.3.0](https://github.com/langdal/devcontainer/compare/v1.2.1...v1.3.0) (2026-06-12)


### Features

* add inference server to allow list ([935139d](https://github.com/langdal/devcontainer/commit/935139d6299c57388129c289151e518be98b0651))
* add inference server to allow list ([8d61644](https://github.com/langdal/devcontainer/commit/8d616448159cf21083c507bb7bbb1ed18ef6f520))
* start container with firewall disabled via --disable-firewall ([ea20a37](https://github.com/langdal/devcontainer/commit/ea20a3797fe06be1d8956d2d7b45891e0742e10e))
* start container with firewall disabled via --disable-firewall ([b01204e](https://github.com/langdal/devcontainer/commit/b01204e324b8fb3eb07537198a974a633f328ad8))


### Bug Fixes

* **dev:** include firewall-disable.sh in create-dev-container scaffold ([4cabc08](https://github.com/langdal/devcontainer/commit/4cabc08067f43cef6d62f7a305b0a0c2ac58d3d9))
* **firewall:** make tinyproxy HUP idempotent to avoid aborting disable script ([f6a6793](https://github.com/langdal/devcontainer/commit/f6a67939dc0d0ad68037211976a88d62b60803f2))
* warn if buildx is not installed ([0391dbc](https://github.com/langdal/devcontainer/commit/0391dbc0308cc7c7185bcc27f62caf8929da7ab3))
* warn if buildx is not installed ([81b6415](https://github.com/langdal/devcontainer/commit/81b641586ac4619e2c9808e334eb9d57823c47e3))

## [1.2.1](https://github.com/langdal/devcontainer/compare/v1.2.0...v1.2.1) (2026-05-30)


### Bug Fixes

* add buildx in dind mode ([6fc568b](https://github.com/langdal/devcontainer/commit/6fc568b6a73dc56e887cd700d5b8fedcd268baa7))
* add buildx in dind mode ([4f9ef35](https://github.com/langdal/devcontainer/commit/4f9ef352077fdc65baa52d14e0004ea2ad8ff69f))
* **dind:** allowlist production.cloudfront.docker.com for Docker Hub pulls ([1607c31](https://github.com/langdal/devcontainer/commit/1607c31cc06e68186238dc635c0c50885957f390))

## [1.2.0](https://github.com/langdal/devcontainer/compare/v1.1.0...v1.2.0) (2026-05-18)


### Features

* **dev:** add --host-port for scoped host-service egress ([77e5fed](https://github.com/langdal/devcontainer/commit/77e5fed608f1ee0f315e0534fe478937fc5841b5))
* **dev:** add --host-port for scoped host-service egress ([4a49174](https://github.com/langdal/devcontainer/commit/4a491749122dbc54737a61aa516324a371e2581c))

## [1.1.0](https://github.com/langdal/devcontainer/compare/v1.0.1...v1.1.0) (2026-05-18)


### Features

* **dev:** container/volume removal with --reset ([d1f9107](https://github.com/langdal/devcontainer/commit/d1f91072461b8abe85a5043a9a91ad4836a6bf25))

## [1.0.1](https://github.com/langdal/devcontainer/compare/v1.0.0...v1.0.1) (2026-05-17)


### Bug Fixes

* **install:** ignore prerelease tags when resolving default REF ([#6](https://github.com/langdal/devcontainer/issues/6)) ([b87e951](https://github.com/langdal/devcontainer/commit/b87e951bab9161199aa8d39d167c59858ae3817e))

## [1.0.0](https://github.com/langdal/devcontainer/compare/v1.0.0-rc.1...v1.0.0) (2026-05-17)


### Features

* add version check on startup ([5b7cdf5](https://github.com/langdal/devcontainer/commit/5b7cdf5b5fde5c3c67b087d4e9204d3d1480a9ff))
* **dev:** add --self-update flag to upgrade the git checkout to the latest tag ([17da386](https://github.com/langdal/devcontainer/commit/17da386a0ebdd005179a8d1f02df34a36f185d7b))
* **dev:** prefer git describe for --version output in working checkouts ([d52fb10](https://github.com/langdal/devcontainer/commit/d52fb10b9d1745c96c3893463fea578cdb13048f))


### Bug Fixes

* **dev:** forward GITHUB_TOKEN to image build as a BuildKit secret so mise install hits authenticated GitHub API ([06ab861](https://github.com/langdal/devcontainer/commit/06ab861eb16b5378dc777aa7b900497b73d1f88b))
* **dev:** suppress AAAA lookups in containers without IPv6 connectivity to avoid tinyproxy EAI_AGAIN on broken upstream resolvers ([fdfb27a](https://github.com/langdal/devcontainer/commit/fdfb27af3b223373f418c8eb99d4afb8fd8dc9b1))


### Miscellaneous Chores

* release 1.0.0 ([f9b5800](https://github.com/langdal/devcontainer/commit/f9b58008ec5b9c841f47211feb87e0f87d4a57b7))

## [1.0.0-rc.1](https://github.com/langdal/devcontainer/compare/v0.1.0...v1.0.0-rc.1) (2026-05-17)


### Features

* add installer ([62c6cab](https://github.com/langdal/devcontainer/commit/62c6cabf59e1f2d49c717a645098e3b648c5ee1d))
* add release-please ([6b1ef91](https://github.com/langdal/devcontainer/commit/6b1ef91e0e43dfc29d1b09fe49174392a95deb33))
* **devcontainer:** add idempotent .zshrc sync in entrypoint ([b4576de](https://github.com/langdal/devcontainer/commit/b4576de7aafe42f11fe2a0c1b9d896387ab0d309))
* **devcontainer:** stage reference files and persist home directory with named volume ([b4576de](https://github.com/langdal/devcontainer/commit/b4576de7aafe42f11fe2a0c1b9d896387ab0d309))
* lock dependencies ([6ec4513](https://github.com/langdal/devcontainer/commit/6ec4513f0ec42b79197ac37799e221caaea08780))
* update compose version ([a7200b6](https://github.com/langdal/devcontainer/commit/a7200b66ac44360f81c8390485748b73eca0c91d))


### Bug Fixes

* **create-dev-container:** firewall must run under VS Code ([84d0417](https://github.com/langdal/devcontainer/commit/84d04175b2043faa367825b4176c1bd04a162ba5))
* macos container resolution issue ([01e9ce8](https://github.com/langdal/devcontainer/commit/01e9ce8367fb82d2724f1786a1a85e519f377723))
* quote inner expansion in update-deps.sh to satisfy SC2295 ([4ad87ab](https://github.com/langdal/devcontainer/commit/4ad87ab06c504d0a03022a756cd4edf685872140))


### Miscellaneous Chores

* release 1.0.0-rc.1 ([664fb5a](https://github.com/langdal/devcontainer/commit/664fb5ab98e663397b5ffff39441513816d5fa7e))
