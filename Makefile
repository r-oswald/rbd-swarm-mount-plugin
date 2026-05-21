PLUGIN_NAME=ghcr.io/r-oswald/rbd-swarm-mount-plugin
PLUGIN_NAME_RO=ghcr.io/r-oswald/rbd-swarm-mount-plugin-ro
PLUGIN_VERSION=4.2.0

PLUGIN_PLATFORM=linux/amd64

all: clean rootfs create

.PHONY: clean
clean:
	@echo "### rm ./plugin"
	@rm -rf ./plugin
	@echo "### rm ./vendor"
	@rm -rf ./vendor

.PHONY: rootfs
rootfs:
	@echo "### docker build: rootfs ${PLUGIN_PLATFORM} image with docker-volume-rbd"
	@docker build --platform ${PLUGIN_PLATFORM} -q -t ${PLUGIN_NAME}:rootfs .
	@echo "### create rootfs directory in ./plugin/rootfs"
	@mkdir -p ./plugin/rootfs
	@docker create --name tmp ${PLUGIN_NAME}:rootfs
	@echo "### export container to a temp tar (avoid pipe-broken issues on CI runners)"
	@docker export -o /tmp/rootfs-export.tar tmp
	@tar -xf /tmp/rootfs-export.tar --exclude=dev/ -C ./plugin/rootfs
	@rm -f /tmp/rootfs-export.tar
	@echo "### copy config.json to ./plugin/"
	@cp config.json ./plugin/
	@docker rm -vf tmp

.PHONY: create
create:
	@echo "### remove existing plugin ${PLUGIN_NAME}:${PLUGIN_VERSION} if exists"
	@docker plugin rm -f ${PLUGIN_NAME}:${PLUGIN_VERSION} || true
	@echo "### create new plugin ${PLUGIN_NAME}:${PLUGIN_VERSION} from ./plugin"
	@docker plugin create ${PLUGIN_NAME}:${PLUGIN_VERSION} ./plugin

# Read-only variant: same rootfs + binary, different config.json (RBD_READONLY=1)
# plus a marker file so the content hash differs from the RW plugin
.PHONY: create-ro
create-ro:
	@echo "### swap in read-only config + content marker"
	@cp config.readonly.json ./plugin/config.json
	@echo readonly > ./plugin/rootfs/etc/rbd-variant
	@docker plugin rm -f ${PLUGIN_NAME_RO}:${PLUGIN_VERSION} || true
	@docker plugin create ${PLUGIN_NAME_RO}:${PLUGIN_VERSION} ./plugin
	@echo "### restore default config"
	@cp config.json ./plugin/config.json
	@rm -f ./plugin/rootfs/etc/rbd-variant

.PHONY: push
push:
	@echo "### push plugin ${PLUGIN_NAME}:${PLUGIN_VERSION}"
	@docker plugin push ${PLUGIN_NAME}:${PLUGIN_VERSION}

.PHONY: push-ro
push-ro:
	@echo "### push plugin ${PLUGIN_NAME_RO}:${PLUGIN_VERSION}"
	@docker plugin push ${PLUGIN_NAME_RO}:${PLUGIN_VERSION}

.PHONY: release
release: clean rootfs create create-ro push push-ro

.PHONY: enable
enable:
	@echo "### enable plugin ${PLUGIN_NAME}:${PLUGIN_VERSION}"
	@docker plugin enable ${PLUGIN_NAME}:${PLUGIN_VERSION}

.PHONY: upgrade
upgrade:
	@echo "### disable plugin ${PLUGIN_NAME}"
	@docker plugin disable -f ${PLUGIN_NAME}
	@echo "### upgrade plugin ${PLUGIN_NAME} to ${PLUGIN_NAME}:${PLUGIN_VERSION}"
	@docker plugin upgrade ${PLUGIN_NAME} ${PLUGIN_NAME}:${PLUGIN_VERSION}
	@echo "### enable plugin ${PLUGIN_NAME}"
	@docker plugin enable ${PLUGIN_NAME}

.PHONY: dev
dev:
	@echo "### docker build: dev ${PLUGIN_PLATFORM} image with golang deps"
	@docker build --platform ${PLUGIN_PLATFORM} -q -t ${PLUGIN_NAME}:dev --target go-builder .
	@echo "### launching interactive shell"
	@docker run --rm -it -v ${PWD}:/go/src/github.com/wetopi/docker-volume-rbd ${PLUGIN_NAME}:dev bash
