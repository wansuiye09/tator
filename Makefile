#Helps to have a line like %sudo ALL=(ALL) NOPASSWD: /bin/systemctl

CONTAINERS=postgis pgbouncer redis transcoder packager tusd gunicorn daphne nginx algorithm submitter pruner sizer

OPERATIONS=reset logs bash

IMAGES=tator-image marshal-image tus-image postgis-image transcoder-image

GIT_VERSION=$(shell git rev-parse HEAD)

DOCKERHUB_USER=$(shell python3 -c 'import yaml; a = yaml.load(open("helm/tator/values.yaml", "r")); print(a["dockerRegistry"])')

POSTGRES_HOST=$(shell python3 -c 'import yaml; a = yaml.load(open("helm/tator/values.yaml", "r")); print(a["postgresHost"])')
POSTGRES_USERNAME=$(shell python3 -c 'import yaml; a = yaml.load(open("helm/tator/values.yaml", "r")); print(a["postgresUsername"])')
POSTGRES_PASSWORD=$(shell python3 -c 'import yaml; a = yaml.load(open("helm/tator/values.yaml", "r")); print(a["postgresPassword"])')

#############################
## Help Rule + Generic targets
#############################
.PHONY: help
help:
	@echo "Tator Online Makefile System"
	@echo  "Generic container operations: (container-action)"
	@echo "\tValid Containers:"
	@echo $(foreach  container, $(CONTAINERS), "\t\t- ${container}\n")
	@echo "\t\t- algorithm"
	@echo "\tValid Operations:"
	@echo $(foreach  operation, $(OPERATIONS), "\t\t- ${operation}\n")
	@echo "\tExample: "
	@echo "\t\tmake tator-reset"
	@echo "\nOther useful targets: "
	@echo "\t\t - collect-static : Runs collect-static on server (manage.py)."
	@echo "\t\t - migrate : Runs migrate on server (manage.py)"
	@echo "\t\t - status : Prints status of container deployment"
	@echo "\t\t - reset : Reset all pods"

	@echo "\t\t - imageQuery: Make sentinel files match docker registry"
	@echo "\t\t - imageHold: Hold sentinel files to current time"
	@echo "\t\t - imageClean: Delete sentinel files + generated dockerfiles"

# Global reset:
reset:
	make $(foreach container, $(CONTAINERS), $(container)-reset)
	kubectl delete jobs --all

# Create backup with pg_dump
backup:
	kubectl exec -it $$(kubectl get pod -l "app=postgis" -o name | head -n 1 | sed 's/pod\///') -- pg_dump -Fc -U django -d tator_online -f /backup/tator_online_$$(date +"%Y_%m_%d__%H_%M_%S")_$(GIT_VERSION).sql;

ecr_update:
	$(eval LOGIN := $(shell aws ecr get-login --no-include-email))
	$(eval KEY := $(shell echo $(LOGIN) | python3 -c 'import sys; print(sys.stdin.read().split()[5])'))
	$(LOGIN)
	echo $(KEY) | python3 -c 'import yaml; import sys; a = yaml.load(open("helm/tator/values.yaml", "r")); a["dockerPassword"] = sys.stdin.read(); yaml.dump(a, open("helm/tator/values.yaml", "w"), default_flow_style=False, default_style="|", sort_keys=False)'

psql_cloud:
	kubectl run psql --image=postgres:11.6 --env="PGPASSWORD=$(POSTGRES_PASSWORD)" --labels="app=psql"
	kubectl exec -it $$(kubectl get pod -l "app=psql" -o name | head -n 1 | sed 's/pod\///') -- psql -h $(POSTGRES_HOST) -U $(POSTGRES_USERNAME)
	kubectl delete deployment.apps/psql

restore_cloud: check_restore
	kubectl run psql --image=postgres:11.6 --env="PGPASSWORD=$(POSTGRES_PASSWORD)" --labels="app=psql"
	kubectl cp $(SQL_FILE) $$(kubectl get pod -l "app=psql" -o name | head -n 1 | sed 's/pod\///'):/.
	kubectl exec -it $$(kubectl get pod -l "app=psql" -o name | head -n 1 | sed 's/pod\///') -- pg_restore -C -h $(POSTGRES_HOST) -U $(POSTGRES_USERNAME) -d tator_online --no-owner --role=$(POSTGRES_USERNAME) --jobs 8 /$(SQL_FILE)
	kubectl delete deployment.apps/psql

# Restore database from specified backup (base filename only)
# Example:
#   make clean
#   make cluster-pvc
#   make postgis
#   make restore SQL_FILE=backup_to_use.sql
#   make cluster
restore: check_restore
	kubectl exec -it $$(kubectl get pod -l "app=postgis" -o name | head -n 1 | sed 's/pod\///') -- pg_restore -C -U django -d tator_online /backup/$(SQL_FILE) --jobs 8

.PHONY: check_restore
check_restore:
	@echo -n "This will replace database contents. Are you sure? [y/N] " && read ans && [ $${ans:-N} = y ]

init-logs:
	kubectl logs $$(kubectl get pod -l "app=gunicorn" -o name | head -n 1 | sed 's/pod\///') -c init-tator-online

# Top-level rule to catch user action + podname and whether it is present
# Sets pod name to the command to execute on each pod.
define generate_rule
$(1)-$(2):
	make podname=$(1) _$(2);
endef

$(foreach action,$(OPERATIONS),$(foreach container,$(CONTAINERS),$(eval $(call generate_rule,$(container),$(action)))))

# Generic handlers (variable podname is set to the requested pod)
_reset:
	kubectl delete pods -l app=$(podname)

_bash:
	kubectl exec -it $$(kubectl get pod -l "app=$(podname)" -o name | head -n 1 | sed 's/pod\///') -- /bin/bash

_logs:
	kubectl describe pod $$(kubectl get pod -l "app=$(podname)" -o name | head -n 1 | sed 's/pod\///')
	kubectl logs $$(kubectl get pod -l "app=$(podname)" -o name | head -n 1 | sed 's/pod\///')


#####################################
## Custom rules below:
#####################################
.PHONY: status
status:
	kubectl get pods -o wide --sort-by="{.spec.nodeName}"

.ONESHELL:

.PHONY: main/version.py
cluster: main/version.py
	$(MAKE) images cluster-deps cluster-install

cluster-deps:
	helm dependency update helm/tator

cluster-install:
	kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.0.0-beta4/aio/deploy/recommended.yaml # No helm chart for this version yet
	helm install --debug --atomic --timeout 60m0s --set gitRevision=$(GIT_VERSION) tator helm/tator

cluster-upgrade: images
	helm upgrade --debug --atomic --timeout 60m0s --set gitRevision=$(GIT_VERSION) tator helm/tator

cluster-uninstall:
	kubectl delete apiservice v1beta1.metrics.k8s.io
	kubectl delete all --namespace kubernetes-dashboard --all
	helm uninstall tator
	kubectl delete pvc --all

dashboard-token:
	kubectl -n kube-system describe secret $$(kubectl -n kube-system get secret | grep tator-kubernetes-dashboard | awk '{print $$1}')

externals/build_tools/%.sh:
	@echo "Downloading submodule"
	@git submodule update --init

externals/build_tools/%.py:
	@echo "Downloading submodule"
	@git submodule update --init

# Add specific rule for marshal's .gen because it uses version input file
containers/tator_algo_marshal/Dockerfile.gen: containers/tator_algo_marshal/Dockerfile.mako scripts/packages/pytator/version
	./externals/build_tools/makocc.py -o $@ containers/tator_algo_marshal/Dockerfile.mako

# Dockerfile.gen rules (generic)
%/Dockerfile.gen: %/Dockerfile.mako
	echo $@ $<
	./externals/build_tools/makocc.py -o $@ $<

tator-image: main/version.py containers/tator/Dockerfile.gen
	$(MAKE) min-js min-css
	docker build $(shell ./externals/build_tools/multiArch.py --buildArgs) -t $(DOCKERHUB_USER)/tator_online:$(GIT_VERSION) -f containers/tator/Dockerfile.gen . || exit 255
	docker push $(DOCKERHUB_USER)/tator_online:$(GIT_VERSION)
	sleep 1
	touch -d "$(shell docker inspect -f '{{ .Created }}' ${DOCKERHUB_USER}/tator_online)" tator-image

PYTATOR_VERSION=$(shell cat scripts/packages/pytator/version)
.PHONY: containers/PyTator-$(PYTATOR_VERSION)-py3-none-any.whl
containers/PyTator-$(PYTATOR_VERSION)-py3-none-any.whl:
	make -C scripts/packages/pytator wheel
	cp scripts/packages/pytator/dist/PyTator-$(PYTATOR_VERSION)-py3-none-any.whl containers
marshal-image:  containers/tator_algo_marshal/Dockerfile.gen containers/PyTator-$(PYTATOR_VERSION)-py3-none-any.whl
	docker build  $(shell ./externals/build_tools/multiArch.py  --buildArgs) -t $(DOCKERHUB_USER)/tator_algo_marshal:latest -f $< containers || exit 255
	docker push $(DOCKERHUB_USER)/tator_algo_marshal:latest
	sleep 1
	touch -d "$(shell docker inspect -f '{{ .Created }}' ${DOCKERHUB_USER}/tator_algo_marshal)" marshal-image

postgis-image:  containers/postgis/Dockerfile.gen
	docker build  $(shell ./externals/build_tools/multiArch.py --buildArgs) -t $(DOCKERHUB_USER)/tator_postgis:latest -f $< containers || exit 255
	docker push $(DOCKERHUB_USER)/tator_postgis:latest
	sleep 1
	touch -d "$(shell docker inspect -f '{{ .Created }}' ${DOCKERHUB_USER}/tator_postgis)" postgis-image

tus-image: containers/tus/Dockerfile.gen
	docker build  $(shell ./externals/build_tools/multiArch.py  --buildArgs) -t $(DOCKERHUB_USER)/tator_tusd:latest -f $< containers || exit 255
	docker push $(DOCKERHUB_USER)/tator_tusd:latest
	sleep 1
	touch -d "$(shell docker inspect -f '{{ .Created }}' ${DOCKERHUB_USER}/tator_tusd)" tus-image

# Publish transcoder image to dockerhub so it can be used cross-cluster
transcoder-image: containers/tator_transcoder/Dockerfile.gen
	docker build $(shell ./externals/build_tools/multiArch.py --buildArgs) -t cvisionai/tator_transcoder:$(GIT_VERSION) -f $< . || exit 255
	docker push cvisionai/tator_transcoder:$(GIT_VERSION)
	sleep 1
	touch -d "$(shell docker inspect -f '{{ .Created }}' cvisionai/tator_transcoder)" tator-transcoder

.PHONY: cross-info
cross-info: ./externals/build_tools/multiArch.py
	./externals/build_tools/multiArch.py  --help

main/version.py:
	externals/build_tools/version.sh > main/version.py
	chmod +x main/version.py

collect-static: min-css min-js
	kubectl exec -it $$(kubectl get pod -l "app=gunicorn" -o name | head -n 1 |sed 's/pod\///') -- rm -rf /tator_online/main/static
	kubectl cp main/static $$(kubectl get pod -l "app=gunicorn" -o name | head -n 1 |sed 's/pod\///'):/tator_online/main
	kubectl exec -it $$(kubectl get pod -l "app=gunicorn" -o name | head -n 1 |sed 's/pod\///') -- rm -f /data/static/js/tator/tator.min.js
	kubectl exec -it $$(kubectl get pod -l "app=gunicorn" -o name | head -n 1 |sed 's/pod\///') -- rm -f /data/static/css/tator/tator.min.css
	kubectl exec -it $$(kubectl get pod -l "app=gunicorn" -o name | head -n 1 |sed 's/pod\///') -- python3 manage.py collectstatic --noinput

dev-push:
	@scripts/dev-push.sh

min-css:
	node_modules/.bin/sass main/static/css/tator/styles.scss:main/static/css/tator/tator.min.css --style compressed

FILES = \
    reconnecting-websocket.min.js \
    node-uuid.js \
    StreamSaver.js \
    zip-stream.js \
    util/get-cookie.js \
    util/identifying-attribute.js \
    util/fetch-retry.js \
    util/has-permission.js \
    components/tator-element.js \
    components/upload-element.js \
    components/labeled-checkbox.js \
    components/modal-close.js \
    components/modal-warning.js \
    components/modal-dialog.js \
    components/cancel-button.js \
    components/cancel-confirm.js \
    components/progress-job.js \
    components/progress-summary.js \
    components/header-notification.js \
    components/header-menu.js \
    components/header-user.js \
    components/header-main.js \
    components/nav-close.js \
    components/nav-back.js \
    components/nav-shortcut.js \
    components/nav-main.js \
    components/keyboard-shortcuts.js \
    components/tator-page.js \
    components/more-icon.js \
    components/form-text.js \
    components/form-file.js \
    components/chevron-right.js \
    components/text-autocomplete.js \
    projects/settings-button.js \
    projects/project-remove.js \
    projects/project-nav.js \
    projects/project-collaborators.js \
    projects/project-description.js \
    projects/project-summary.js \
    projects/new-project.js \
    projects/delete-project.js \
    projects/projects-dashboard.js \
    new-project/new-project-close.js \
    new-project/custom/custom-form.js \
    new-project/custom/custom.js \
    project-detail/new-algorithm-button.js \
    project-detail/algorithm-menu.js \
    project-detail/algorithm-button.js \
    project-detail/upload-button.js \
    project-detail/project-text.js \
    project-detail/project-search.js \
    project-detail/new-section.js \
    project-detail/section-search.js \
    project-detail/section-upload.js \
    project-detail/download-button.js \
    project-detail/rename-button.js \
    project-detail/delete-button.js \
    project-detail/section-more.js \
    project-detail/media-move.js \
    project-detail/media-more.js \
    project-detail/media-description.js \
    project-detail/media-card.js \
    project-detail/section-prev.js \
    project-detail/section-next.js \
    project-detail/section-expand.js \
    project-detail/section-paginator.js \
    project-detail/section-files.js \
    project-detail/section-overview.js \
    project-detail/media-section.js \
    project-detail/delete-section-form.js \
    project-detail/delete-file-form.js \
    project-detail/new-algorithm-form.js \
    project-detail/project-detail.js \
    project-settings/project-settings.js \
    annotation/annotation-breadcrumbs.js \
    annotation/media-capture-button.js \
    annotation/media-link-button.js \
    annotation/media-prev-button.js \
    annotation/media-next-button.js \
    annotation/zoom-control.js \
    annotation/rate-control.js \
    annotation/annotation-settings.js \
    annotation/edit-button.js \
    annotation/box-button.js \
    annotation/line-button.js \
    annotation/point-button.js \
    annotation/zoom-in-button.js \
    annotation/zoom-out-button.js \
    annotation/pan-button.js \
    annotation/annotation-sidebar.js \
    annotation/rewind-button.js \
    annotation/play-button.js \
    annotation/fast-forward-button.js \
    annotation/frame-prev.js \
    annotation/frame-next.js \
    annotation/timeline-canvas.js \
    annotation/video-fullscreen.js \
    annotator/FrameBuffer.js \
    annotator/drawGL_colors.js \
    annotator/drawGL.js \
    annotator/annotation.js \
    annotator/video.js \
    annotator/image.js \
    annotation/annotation-player.js \
    annotation/annotation-image.js \
    annotation/bool-input.js \
    annotation/enum-input.js \
    annotation/text-input.js \
    annotation/attribute-panel.js \
    annotation/recents-panel.js \
    annotation/save-dialog.js \
    annotation/entity-button.js \
    annotation/media-panel.js \
    annotation/frame-panel.js \
    annotation/entity-browser.js \
    annotation/entity-prev-button.js \
    annotation/entity-next-button.js \
    annotation/entity-delete-button.js \
    annotation/entity-more.js \
    annotation/entity-selector.js \
    annotation/annotation-browser.js \
    annotation/undo-buffer.js \
    annotation/annotation-data.js \
    annotation/annotation-page.js \
    annotation/seek-bar.js \
    third_party/autocomplete.js \
    utilities.js

JSDIR = main/static/js
OUTDIR = main/static/js/tator

define generate_minjs
.min_js/${1:.js=.min.js}: $(JSDIR)/${1}
	@mkdir -p .min_js/$(shell dirname ${1})
	@echo "Building '${1:.js=.min.js}'"
	node_modules/.bin/babel-minify $(JSDIR)/${1} -o .min_js/${1:.js=.min.js}
endef
$(foreach file,$(FILES),$(eval $(call generate_minjs,$(file))))


USE_MIN_JS=$(shell cat tator_online/settings.py | grep USE_MIN_JS | grep True | wc -l)
ifeq ($(USE_MIN_JS),1)
min-js:
	@echo "Building min-js file, because USE_MIN_JS is true"
	mkdir -p $(OUTDIR)
	rm -f $(OUTDIR)/tator.min.js
	mkdir -p .min_js
	@$(foreach file,$(FILES),make --no-print-directory .min_js/$(file:.js=.min.js); cat .min_js/$(file:.js=.min.js) >> $(OUTDIR)/tator.min.js;)
else
min-js:
	@echo "Skipping min-js, because USE_MIN_JS is false"
endif

migrate:
	kubectl exec -it $$(kubectl get pod -l "app=gunicorn" -o name | head -n 1 | sed 's/pod\///') -- python3 manage.py makemigrations
	kubectl exec -it $$(kubectl get pod -l "app=gunicorn" -o name | head -n 1 | sed 's/pod\///') -- python3 manage.py migrate

testinit:
	kubectl exec -it $$(kubectl get pod -l "app=postgis" -o name | head -n 1 | sed 's/pod\///') -- psql -U django -d tator_online -c 'CREATE DATABASE test_tator_online';
	kubectl exec -it $$(kubectl get pod -l "app=postgis" -o name | head -n 1 | sed 's/pod\///') -- psql -U django -d test_tator_online -c 'CREATE EXTENSION LTREE';

test:
	kubectl exec -it $$(kubectl get pod -l "app=gunicorn" -o name | head -n 1 | sed 's/pod\///') -- python3 -c 'from elasticsearch import Elasticsearch; import os; es = Elasticsearch(host=os.getenv("ELASTICSEARCH_HOST")).indices.delete("test*")'
	kubectl exec -it $$(kubectl get pod -l "app=gunicorn" -o name | head -n 1 | sed 's/pod\///') -- sh -c 'ELASTICSEARCH_PREFIX=test python3 manage.py test --keep'

mrclean:
	kubectl patch pvc media-pv-claim -p '{"metadata":{"finalizers":null}}'
	make clean_js
clean:
	kubectl delete deployment.apps --all
	kubectl delete statefulsets --all
	kubectl delete daemonsets --all
	kubectl delete jobs --all
	kubectl delete pods --all
	kubectl delete svc --all
	kubectl delete pvc --all
	kubectl delete pv --all
	kubectl delete networkpolicy --all
	kubectl delete configmaps --all

.PHONY: cache_clear
cache-clear:
	kubectl exec -it $$(kubectl get pod -l "app=gunicorn" -o name | head -n 1 | sed 's/pod\///') -- python3 -c 'from main.cache import TatorCache;TatorCache().invalidate_all()'

.PHONY: clean_js
clean_js:
	rm -rf .min_js
images:
	make ${IMAGES}

imageClean:
	rm -f ${IMAGES}
	rm -f `find . -name Dockerfile.gen`

imageHold:
	touch ${IMAGES}

imageQuery:
	touch -d "$(shell docker inspect -f '{{ .Created }}' ${DOCKERHUB_USER}/tator_online)" tator-image
	touch -d "$(shell docker inspect -f '{{ .Created }}' ${DOCKERHUB_USER}/tator_algo_marshal)" marshal-image
	touch -d "$(shell docker inspect -f '{{ .Created }}' ${DOCKERHUB_USER}/tator_tusd)" tus-image
	touch -d "$(shell docker inspect -f '{{ .Created }}' ${DOCKERHUB_USER}/tator_postgis)" postgis-image
	touch -d "$(shell docker inspect -f '{{ .Created }}' ${DOCKERHUB_USER}/tator_transcoder)" transcoder-image

lazyPush:
	rsync -a -e ssh --exclude main/migrations --exclude main/__pycache__ main adamant:/home/brian/working/tator_online
