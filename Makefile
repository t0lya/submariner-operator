BASE_BRANCH ?= devel
# Denotes the default operator image version, exposed as a variable for the automated release
DEFAULT_IMAGE_VERSION ?= $(BASE_BRANCH)
export BASE_BRANCH
export DEFAULT_IMAGE_VERSION

# Define LOCAL_BUILD to build directly on the host and not inside a Dapper container
ifdef LOCAL_BUILD
DAPPER_HOST_ARCH ?= $(shell go env GOHOSTARCH)
SHIPYARD_DIR ?= ../shipyard
SCRIPTS_DIR ?= $(SHIPYARD_DIR)/scripts/shared

export DAPPER_HOST_ARCH
export SHIPYARD_DIR
export SCRIPTS_DIR
endif

ifneq (,$(DAPPER_HOST_ARCH))

OPERATOR_SDK := $(CURDIR)/bin/operator-sdk
KUSTOMIZE := $(CURDIR)/bin/kustomize
CONTROLLER_GEN := $(CURDIR)/bin/controller-gen

# Running in Dapper

# Semantic versioning regex
PATTERN := ^([0-9]|[1-9][0-9]*)\.([0-9]|[1-9][0-9]*)\.([0-9]|[1-9][0-9]*)$
# Test if VERSION matches the semantic versioning rule
IS_SEMANTIC_VERSION = $(shell [[ $(or $(BUNDLE_VERSION),$(VERSION),'undefined') =~ $(PATTERN) ]] && echo true || echo false)

gotodockerarch = $(patsubst arm,arm/v7,$(1))
dockertogoarch = $(patsubst arm/v7,arm,$(1))

PLATFORMS ?= linux/amd64,linux/arm64
IMAGES = submariner-operator
MULTIARCH_IMAGES := submariner-operator

ifneq (,$(filter ovn,$(USING)))
SETTINGS = $(DAPPER_SOURCE)/.shipyard.e2e.ovn.yml
else
SETTINGS = $(DAPPER_SOURCE)/.shipyard.e2e.yml
endif

include $(SHIPYARD_DIR)/Makefile.inc

override UNIT_TEST_ARGS += test internal/env

GO ?= go
GOARCH = $(shell $(GO) env GOARCH)
GOEXE = $(shell $(GO) env GOEXE)
GOOS = $(shell $(GO) env GOOS)

BINARIES := bin/$(GOOS)/$(GOARCH)/submariner-operator

# Options for 'submariner-operator-bundle' image
ifeq ($(IS_SEMANTIC_VERSION),true)
BUNDLE_VERSION := $(VERSION)
else
BUNDLE_VERSION := $(shell (git describe --abbrev=0 --tags --match=v[0-9]*\.[0-9]*\.[0-9]* 2>/dev/null || echo v9.9.9) \
| cut -d'-' -f1 | cut -c2-)
endif
FROM_VERSION ?= $(shell (git tag -l --sort=-v:refname v[0-9]*\.[0-9]*\.[0-9]* | awk '/^$(BUNDLE_VERSION)$$/ { seen = 1; next } seen { print; exit } END { exit !seen }' || echo v0.0.0) \
          | head -n1 | cut -d'-' -f1 | cut -c2-)
SHORT_VERSION := $(shell echo ${BUNDLE_VERSION} | cut -d'.' -f1,2)
CHANNEL ?= alpha-$(SHORT_VERSION)
CHANNELS ?= $(CHANNEL)
DEFAULT_CHANNEL ?= $(CHANNEL)
ifneq ($(origin CHANNELS), undefined)
BUNDLE_CHANNELS := --channels=$(CHANNELS)
endif
ifneq ($(origin DEFAULT_CHANNEL), undefined)
BUNDLE_DEFAULT_CHANNEL := --default-channel=$(DEFAULT_CHANNEL)
endif
BUNDLE_METADATA_OPTS ?= $(BUNDLE_CHANNELS) $(BUNDLE_DEFAULT_CHANNEL)
IS_CHANNEL_DEFAULT ?= 1
ifneq ($(origin FROM_VERSION), undefined)
ifneq ($(FROM_VERSION), 0.0.0)
PKG_FROM_VERSION := --from-version=$(FROM_VERSION)
REPLACES_OP := add
else
REPLACES_OP := remove
endif
endif
ifneq ($(origin CHANNEL), undefined)
PKG_CHANNELS := --channel=$(CHANNEL)
endif
ifeq ($(IS_CHANNEL_DEFAULT), 1)
PKG_IS_DEFAULT_CHANNEL := --default-channel
endif
PKG_MAN_OPTS ?= $(PKG_FROM_VERSION) $(PKG_CHANNELS) $(PKG_IS_DEFAULT_CHANNEL)

# Set the kustomize base path
ifeq ($(IS_OCP), true)
KUSTOMIZE_BASE_PATH := $(CURDIR)/config/openshift
else
KUSTOMIZE_BASE_PATH := $(CURDIR)/config/manifests
endif

# Image URL to use all building/pushing image targets
REPO ?= quay.io/submariner
IMG ?= $(REPO)/submariner-operator:$(VERSION)
# Produce v1 CRDs, requiring Kubernetes 1.16 or later
CRD_OPTIONS ?= "crd:crdVersions=v1"

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell $(GO) env GOBIN))
GOBIN=$(shell $(GO) env GOPATH)/bin
else
GOBIN=$(shell $(GO) env GOBIN)
endif

# Ensure we prefer binaries we build
export PATH := $(CURDIR)/bin:$(PATH)

# Targets to make

build: $(BINARIES)

e2e:
	scripts/test/e2e.sh cluster1 cluster2

# [system-test] runs system level tests that validate the operator is properly deployed
system-test:
	scripts/test/system.sh

clean:
	rm -f $(BINARIES)

licensecheck: export BUILD_UPX = false
licensecheck: $(BINARIES) | bin/lichen
	bin/lichen -c .lichen.yaml $(BINARIES)

bin/lichen:
	mkdir -p $(@D)
	cd tools && $(GO) build -o $(CURDIR)/$@ github.com/uw-labs/lichen

# Generate deep-copy code
CONTROLLER_DEEPCOPY := api/v1alpha1/zz_generated.deepcopy.go
$(CONTROLLER_DEEPCOPY): | $(CONTROLLER_GEN)
	$(CONTROLLER_GEN) object:headerFile="$(CURDIR)/hack/boilerplate.go.txt,year=$(shell date +"%Y")" paths="./..."

# Generate embedded YAMLs
EMBEDDED_YAMLS := pkg/embeddedyamls/yamls.go
$(EMBEDDED_YAMLS): pkg/embeddedyamls/generators/yamls2go.go deploy/crds/submariner.io_servicediscoveries.yaml deploy/crds/submariner.io_brokers.yaml deploy/crds/submariner.io_submariners.yaml deploy/submariner/crds/submariner.io_clusterglobalegressips.yaml deploy/submariner/crds/submariner.io_clusters.yaml deploy/submariner/crds/submariner.io_endpoints.yaml deploy/submariner/crds/submariner.io_gatewayroutes.yaml deploy/submariner/crds/submariner.io_gateways.yaml deploy/submariner/crds/submariner.io_globalegressips.yaml deploy/submariner/crds/submariner.io_globalingressips.yaml deploy/submariner/crds/submariner.io_nongatewayroutes.yaml deploy/submariner/crds/submariner.io_routeagents.yaml $(shell find deploy/ -name "*.yaml") $(shell find config/rbac/ -name "*.yaml") $(CONTROLLER_DEEPCOPY)
	$(GO) generate pkg/embeddedyamls/generate.go

bin/%/submariner-operator: cmd/main.go $(EMBEDDED_YAMLS)
	GOARCH=$(call dockertogoarch,$(patsubst bin/linux/%/,%,$(dir $@))) \
	LDFLAGS="-X=main.version=$(VERSION)" \
	${SCRIPTS_DIR}/compile.sh $@ ./cmd

ci: $(EMBEDDED_YAMLS) golangci-lint markdownlint unit build images

# Download controller-gen locally if not already downloaded.
$(CONTROLLER_GEN):
	mkdir -p $(@D)
	cd tools && $(GO) build -o $@ sigs.k8s.io/controller-tools/cmd/controller-gen

controller-gen: $(CONTROLLER_GEN)

# Operator CRDs
deploy/crds/submariner.io_servicediscoveries.yaml: ./api/v1alpha1/servicediscovery_types.go | $(CONTROLLER_GEN)
	$(CONTROLLER_GEN) $(CRD_OPTIONS) paths="./..." output:crd:artifacts:config=deploy/crds
	test -f $@

deploy/crds/submariner.io_brokers.yaml deploy/crds/submariner.io_submariners.yaml: ./api/v1alpha1/submariner_types.go | $(CONTROLLER_GEN)
	$(CONTROLLER_GEN) $(CRD_OPTIONS) paths="./..." output:crd:artifacts:config=deploy/crds
	test -f $@

# Submariner CRDs
deploy/submariner/crds/submariner.io_clusterglobalegressips.yaml deploy/submariner/crds/submariner.io_clusters.yaml deploy/submariner/crds/submariner.io_endpoints.yaml deploy/submariner/crds/submariner.io_gatewayroutes.yaml deploy/submariner/crds/submariner.io_gateways.yaml deploy/submariner/crds/submariner.io_globalegressips.yaml deploy/submariner/crds/submariner.io_globalingressips.yaml deploy/submariner/crds/submariner.io_nongatewayroutes.yaml deploy/submariner/crds/submariner.io_routeagents.yaml: | $(CONTROLLER_GEN)
	$(CONTROLLER_GEN) $(CRD_OPTIONS) paths="github.com/submariner-io/submariner/pkg/apis/..." output:crd:artifacts:config=deploy/submariner/crds
	test -f $@

# Generate manifests e.g. CRD etc.
manifests: $(CONTROLLER_DEEPCOPY) $(CONTROLLER_GEN)
	$(CONTROLLER_GEN) $(CRD_OPTIONS) paths="./..." output:crd:artifacts:config=config/crd/bases

# test if VERSION matches the semantic versioning rule
is-semantic-version:
    ifneq ($(IS_SEMANTIC_VERSION),true)
	    $(error 'ERROR: VERSION "$(BUNDLE_VERSION)" does not match the format required by operator-sdk.')
    endif

# Download kustomize locally if not already downloaded.
# We clear GITHUB_TOKEN to ensure that the installation script won't try to use it (and fail)
KUSTOMIZE_INSTALL_SCRIPT ?= "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh"
KUSTOMIZE_VERSION := $(shell cd tools && $(GO) list -m -f {{.Version}} sigs.k8s.io/kustomize/kustomize/v5)
$(KUSTOMIZE):
	mkdir -p $(@D)
	{ curl -s $(KUSTOMIZE_INSTALL_SCRIPT) | GITHUB_TOKEN= bash -s -- $(subst v,,$(KUSTOMIZE_VERSION)) $(@D); }

kustomize: $(KUSTOMIZE)

# Generate kustomization.yaml for bundle
kustomization: $(OPERATOR_SDK) $(KUSTOMIZE) is-semantic-version manifests
	$(OPERATOR_SDK) generate kustomize manifests -q
	(cd config/manifests && $(KUSTOMIZE) edit set image controller=$(IMG) && \
	 $(KUSTOMIZE) edit set image repo=$(REPO))
	sed -e 's/$${VERSION}/$(BUNDLE_VERSION)/g' config/bundle/kustomization.template.yaml > config/bundle/kustomization.yaml
	sed -e 's/$${REPLACES_OP}/$(REPLACES_OP)/g' -e 's/$${FROM_VERSION}/$(FROM_VERSION)/g' \
		config/bundle/patches/submariner.csv.template.yaml > config/bundle/patches/submariner.csv.config.yaml
	(cd config/bundle && \
	$(KUSTOMIZE) edit add annotation createdAt:"$(shell date "+%Y-%m-%d %T")" -f)

# Generate bundle manifests and metadata, then validate generated files
bundle: $(KUSTOMIZE) $(OPERATOR_SDK) kustomization
	(set -o pipefail; $(KUSTOMIZE) build $(KUSTOMIZE_BASE_PATH) \
	| $(OPERATOR_SDK) generate bundle -q --overwrite --version $(BUNDLE_VERSION) $(BUNDLE_METADATA_OPTS))
	(cd config/bundle && $(KUSTOMIZE) edit add resource ../../bundle/manifests/submariner.clusterserviceversion.yaml)
	$(KUSTOMIZE) build config/bundle/ --load-restrictor=LoadRestrictionsNone --output bundle/manifests/submariner.clusterserviceversion.yaml
	sed -i -e 's/$$(SHORT_VERSION)/$(SHORT_VERSION)/g' bundle/manifests/submariner.clusterserviceversion.yaml
	sed -i -e 's/$$(VERSION)/$(VERSION)/g' bundle/manifests/submariner.clusterserviceversion.yaml
	$(OPERATOR_SDK) bundle validate --select-optional suite=operatorframework ./bundle

# Statically validate the operator bundle using Scorecard.
scorecard: bundle olm clusters
	timeout 60 bash -c "until KUBECONFIG=$(DAPPER_OUTPUT)/kubeconfigs/kind-config-cluster1 \
	$(OPERATOR_SDK) olm status > /dev/null; do sleep 10; done"
	$(OPERATOR_SDK) scorecard --kubeconfig=$(DAPPER_OUTPUT)/kubeconfigs/kind-config-cluster1 -o text ./bundle

# Create the clusters with olm
olm: export OLM = true

golangci-lint: $(EMBEDDED_YAMLS)

unit: $(EMBEDDED_YAMLS)

# Operator SDK
# If necessary, the verification *keys* can be updated as follows:
# * update scripts/operator-sdk-signing-key.asc, import the relevant key,
#   and export it with
#     gpg --armor --export-options export-minimal --export \
#     ${fingerprint} >> scripts/operator-sdk-signing-key.asc
#   (replacing ${fingerprint} with the full fingerprint);
# * to update scripts/operator-sdk-signing-keyring.gpg, run
#     gpg --no-options -q --batch --no-default-keyring \
#     --output scripts/operator-sdk-signing-keyring.gpg \
#     --dearmor scripts/operator-sdk-signing-key.asc
OPERATOR_SDK_VERSION := $(shell cd tools && $(GO) list -m -f {{.Version}} github.com/operator-framework/operator-sdk)
OPERATOR_SDK_REPO := github.com/operator-framework/operator-sdk
$(OPERATOR_SDK):
	mkdir -p $(@D) && \
	cd $(@D) && \
	curl -LO "https://github.com/operator-framework/operator-sdk/releases/download/${OPERATOR_SDK_VERSION}/operator-sdk_linux_amd64" \
	      -O "https://github.com/operator-framework/operator-sdk/releases/download/${OPERATOR_SDK_VERSION}/checksums.txt.asc" \
	      -O "https://github.com/operator-framework/operator-sdk/releases/download/${OPERATOR_SDK_VERSION}/checksums.txt" && \
	sha256sum -c --ignore-missing --quiet checksums.txt
	gpgv --keyring scripts/operator-sdk-signing-keyring.gpg bin/checksums.txt.asc bin/checksums.txt
	mv bin/operator-sdk_linux_amd64 "$@"
	chmod a+x $@
	rm bin/checksums.txt*

operator-sdk: $(OPERATOR_SDK)

.PHONY: build ci clean bundle kustomization is-semantic-version olm scorecard system-test controller-gen kustomize operator-sdk

else

# Not running in Dapper

Makefile.dapper:
	@echo Downloading $@
	@curl -sfLO https://raw.githubusercontent.com/submariner-io/shipyard/$(BASE_BRANCH)/$@

include Makefile.dapper

.PHONY: deploy bundle kustomization is-semantic-version licensecheck controller-gen kustomize operator-sdk

endif

# Disable rebuilding Makefile
Makefile Makefile.inc: ;
