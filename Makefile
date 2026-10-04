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
# privileged, on the host network. They see host PIDs so they can inspect the
# add-on's processes from outside (docker exec would run under its AppArmor profile).
RUN_PRIV = docker run --rm -v "$(CURDIR):$(CURDIR)" -w "$(CURDIR)" \
	--privileged --network host --pid host -v /var/run/docker.sock:/var/run/docker.sock \
	$(TOOLBOX)
endif

.PHONY: toolbox lint unit functional test clean

toolbox:
ifneq ($(IN_TOOLBOX),1)
	docker build -q -t $(TOOLBOX) tests/toolbox > /dev/null
endif

lint: toolbox
	$(RUN) shellcheck nfs-ganesha/*.sh $(wildcard scripts/*.sh tests/functional/*.bash tests/haos/*.sh)
	$(RUN) hadolint --config .hadolint.yaml nfs-ganesha/Dockerfile tests/toolbox/Dockerfile tests/haos/Dockerfile
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
	-$(RUN_PRIV) sh -c '[ -d /sys/kernel/security/apparmor ] || mount -t securityfs securityfs /sys/kernel/security; \
		printf nfs_ganesha_test > /sys/kernel/security/apparmor/.remove' 2>/dev/null
