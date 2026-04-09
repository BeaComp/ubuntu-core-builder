
# 🔐 Guia de Autenticação e Configuração de Chaves (Ubuntu Core)

Para gerar imagens customizadas do Ubuntu Core, é estritamente necessário que a imagem seja assinada por uma chave criptográfica validada pela Canonical (Snap Store).

Este guia explica como fazer a configuração inicial de segurança **dentro do container Docker**, garantindo que suas senhas não fiquem expostas no código-fonte.

## ⚠️ Pré-requisitos
1. O container Docker `ubuntu-core-builder` deve estar rodando (use o script de inicialização):
```bash
docker compose up -d
```

2. Você precisa ter uma conta ativa no **Ubuntu One** (https://login.ubuntu.com).
3. Você deve ter aceito os Termos de Desenvolvedor no painel da **Snapcraft** (https://dashboard.snapcraft.io).

---

## 🛠️ Passo a Passo (Setup Inicial)

Todas as operações abaixo devem ser feitas **uma única vez** por máquina/ambiente.

### Passo 1: Instalar as dependências
Inicie o script que baixará as depedências no container para gerar a imagem:
```bash
docker exec -it ubuntu-core-builder /workspace/check-dependency.sh
```

### Passo 2: Entrar no Container
Abra o seu terminal e acesse o bash interativo do container com privilégios de root:
```bash
docker exec -it ubuntu-core-builder bash
```

### Passo 3: Configurar o Caminho do Snap
Dentro do container, garanta que o terminal consegue encontrar os comandos do Snapcraft:
```bash
export PATH=$PATH:/snap/bin
```

### Passo 4: Fazer Login e Gerar o Token Seguro
Para evitar colocar senhas em scripts, vamos gerar um token de acesso duradouro e salvá-lo na pasta `workspace`. Para isso, faça o login da sua conta Ubuntu One:

* **Nota:** O terminal vai pedir o seu email, senha do Ubuntu One e o código de Autenticação de 2 Fatores (caso você tenha ativado).
```bash
snapcraft login
```

Após isso, exporte seu token seguro:
* **Nota:** É provável que o terminal irá perguntar novamente seu email e senha do Ubuntu One.
```bash
snapcraft export-login /workspace/credentials.txt
```

### Passo 5: Carregar o Token na Sessão Atual
Para o próximo passo funcionar, diga ao terminal para usar o token que você acabou de gerar no Passo 3:
```bash
export SNAPCRAFT_STORE_CREDENTIALS=$(cat /workspace/credentials.txt)
```

* **Nota:** O arquivo gerado (`credentials.txt`) é o seu passaporte e nunca deve ser "commitado" no Git.

### Passo 6: Criar a Chave de Assinatura Local
Agora, vamos criar a chave criptográfica que vai assinar os seus arquivos (`model.json` e `system-user`). Substitua `NOME_DA_SUA_CHAVE` por um nome único para o seu projeto (ex: `chave-projeto-iot`).
```bash
snapcraft create-key NOME_DA_SUA_CHAVE
```
* **Nota:** Ele vai pedir para você criar uma **Passphrase** (senha da chave). Anote essa senha, você vai precisar dela no arquivo `.env`.

### Passo 7: Registrar a Chave na Canonical (Nuvem)
Este é o passo mais crítico. O Ubuntu Core exige uma "corrente de confiança" (`--chain`). Para isso, a Canonical precisa saber que essa chave pertence à sua conta.
```bash
snapcraft register-key NOME_DA_SUA_CHAVE
```
* **Sucesso:** Se tudo der certo, o terminal vai responder com *Key successfully registered*.

### Passo 8: Descobrir o seu Developer ID
Para que você tenha permissão de assinar a imagem, o arquivo `model.json` precisa conter o seu ID de desenvolvedor da Canonical. Para descobrir qual é o seu, digite:
```bash
snapcraft whoami
```
* **Nota:** O comando vai imprimir algo como `seu-email@exemplo.com (developer-id: YbZ78x...)`. Copie o código alfanumérico que está dentro dos parênteses.

### Passo 9: Sair do Container
A configuração manual está finalizada. Digite `exit` para voltar ao terminal da sua máquina real.
```bash
exit
```

---

## 📝 Integração com o Projeto

Agora que o ambiente seguro foi criado, você precisa alimentar o projeto com essas informações.

**1. Atualize o arquivo `.env`:**
No seu arquivo `.env` (na pasta `workspace`), coloque o nome da chave que você registrou e a passphrase que você inventou no Passo 4:
```text
KEY_NAME="NOME_DA_SUA_CHAVE"
KEY_PASSPHRASE="sua_senha_secreta"
```

**2. Atualize o arquivo `model.json`:**
Abra o arquivo `model.json` e substitua os campos de `authority-id` e `brand-id` pelo código que você copiou no Passo 7:
```json
{
  "type": "model",
  "series": "16",
  "authority-id": "COLE_O_SEU_DEVELOPER_ID_AQUI",
  "brand-id": "COLE_O_SEU_DEVELOPER_ID_AQUI",
}
...
```

**Pronto!** O ambiente está autenticado e o script automático `build-image.sh` já pode ser executado.

```bash
docker exec -it ubuntu-core-builder /workspace/build-image.sh
```