# ════════════════════════════════════════════════════════════════
#  Ubuntu Core Image Pipeline — comandos de conveniência (host)
#
#  Fluxo típico:
#    make up      # arranca o container (1ª vez faz build)
#    make setup   # login Ubuntu One + chave (interativo, 1 vez)
#    make image   # build completo da imagem (não-interativo)
# ════════════════════════════════════════════════════════════════

CONTAINER := ubuntu-core-builder
COMPOSE   := docker compose
EXEC      := docker exec -it $(CONTAINER)
PIPELINE  := /workspace/pipeline.sh

.PHONY: help up down rebuild shell setup image gadget doctor clean logs ci-secrets

help: ## Mostra esta ajuda
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  \033[1m%-10s\033[0m %s\n", $$1, $$2}'

up: ## Arranca o container de build
	$(COMPOSE) up -d --build
	@echo "A aguardar que o snapd fique pronto..."
	@$(EXEC) sh -c 'until snap wait system seed.loaded 2>/dev/null; do sleep 2; done' || true

down: ## Pára o container
	$(COMPOSE) down

rebuild: ## Reconstrói a imagem Docker do zero
	$(COMPOSE) build --no-cache
	$(COMPOSE) up -d

shell: ## Abre um bash dentro do container
	$(EXEC) bash

setup: ## Setup inicial: login na Store + criação/registo da chave (interativo)
	$(EXEC) $(PIPELINE) setup

image: ## Build completo da imagem Ubuntu Core (não-interativo)
	$(EXEC) $(PIPELINE) build

gadget: ## Build da imagem forçando reconstrução do gadget
	$(EXEC) $(PIPELINE) build --rebuild-gadget

doctor: ## Diagnóstico do ambiente (deps, auth, chave, templates)
	$(EXEC) $(PIPELINE) doctor

clean: ## Remove artefactos de build (preserva credenciais e imagens)
	$(EXEC) $(PIPELINE) clean

logs: ## Segue os logs do container
	docker logs -f $(CONTAINER)

ci-secrets: ## Copia credenciais + chave de assinatura para os secrets do GitHub (requer gh autenticado)
	@KEY=$$(grep -E '^KEY_NAME=' workspace/.env | cut -d= -f2 | tr -d '"'); \
	echo "A enviar secrets para o repositório GitHub (chave: $$KEY)..."; \
	docker exec $(CONTAINER) cat /workspace/.credentials/snapcraft-store.txt \
		| gh secret set SNAPCRAFT_STORE_CREDENTIALS; \
	docker exec $(CONTAINER) gpg --homedir /root/.snap/gnupg --export-secret-keys --armor "$$KEY" \
		| gh secret set SNAP_SIGNING_KEY; \
	echo "✔ Feito. Se a chave tiver passphrase, define também: gh secret set KEY_PASSPHRASE"
