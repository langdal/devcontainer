# Changelog

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
