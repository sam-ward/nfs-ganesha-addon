# Every target runs inside the test toolbox image (tests/toolbox/Dockerfile),
# so the host only needs Docker and make. Inside the toolbox (IN_TOOLBOX=1)
# the commands run directly.
TOOLBOX := nfs-ganesha-addon-toolbox

ifeq ($(IN_TOOLBOX),1)
RUN :=
RUN_PRIV :=
else
# Repo is mounted at the same path so nested `docker run -v` paths resolve on the host.
RUN = docker run --rm -v "$(CURDIR):$(CURDIR)" -w "$(CURDIR)" \
	--user "$$(id -u):$$(id -g)" $(TOOLBOX)
# Functional tests mount NFS and drive the host's Docker, so they run as root,
# privileged, on the host network.
RUN_PRIV = docker run --rm -v "$(CURDIR):$(CURDIR)" -w "$(CURDIR)" \
	--privileged --network host -v /var/run/docker.sock:/var/run/docker.sock \
	$(TOOLBOX)
endif

.PHONY: toolbox lint unit functional test clean

toolbox:
ifneq ($(IN_TOOLBOX),1)
	docker build -q -t $(TOOLBOX) tests/toolbox > /dev/null
endif

lint: toolbox
	$(RUN) shellcheck nfs-ganesha/*.sh $(wildcard scripts/*.sh tests/functional/*.bash)
	$(RUN) hadolint --config .hadolint.yaml nfs-ganesha/Dockerfile tests/toolbox/Dockerfile
	$(RUN) yamllint .
	$(RUN) scripts/check-version.sh

unit: toolbox
	$(RUN) bats tests/unit

functional: toolbox
	$(RUN_PRIV) bats tests/functional

test: lint unit functional

# Functional tests run as root; remove anything an interrupted run left behind.
clean: toolbox
	-docker rm -f nfs-ganesha-functional > /dev/null 2>&1
	$(RUN_PRIV) rm -rf .test-work .test-logs
