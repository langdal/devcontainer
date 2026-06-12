# Changelog

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
