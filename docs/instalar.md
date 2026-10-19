# Instalar o Hexápode

[English](install.md) · **Português**

Este guia é para quem **não usa terminal**: você grava um cartão no PC, liga o robô e configura tudo pelo celular. Quem quiser mexer no sistema (SSH, Ansible) tem o caminho do maker em [`pi/provision/README.md`](../pi/provision/README.md).

## Do que você precisa

- O robô montado, com o **Raspberry Pi 3** e o **ESP32-S3** ligados.
- Um **cartão microSD** de 16 GB ou mais.
- Um **PC** com leitor de cartão.
- Um **celular Android 10 ou mais novo**.
- **Energia de verdade.** Com fonte fraca, o Raspberry desliga o Wi-Fi e a tela apaga. No robô, a energia vem da bateria pelo regulador. Na bancada, use a fonte oficial do Raspberry (5,1 V / 2,5 A). Carregador de celular não serve.

## 1. Gravar o cartão (no PC, uma vez)

1. Na página de **Releases** do projeto, baixe o arquivo `hexapod-…-esp32s3.img.xz`. Não precisa descompactar.
2. Instale o **Raspberry Pi Imager**: [raspberrypi.com/software](https://www.raspberrypi.com/software/).
3. No Imager:
   - **Dispositivo:** Raspberry Pi 3.
   - **Sistema operacional:** role até o fim → **Usar personalizado** → escolha o arquivo baixado.
   - **Armazenamento:** o seu cartão. Confira o tamanho, para não apagar outro disco.
4. Quando o Imager perguntar se quer **personalizar**, pode responder **Não**. O robô se configura sozinho.
   - Opcional: se você já quer o robô na rede de casa, informe o **Wi-Fi** ali. Só redes **2,4 GHz**, porque o Wi-Fi do Raspberry Pi 3 não enxerga 5 GHz.
5. **Gravar.** Espere terminar e verificar.

## 2. Ligar o robô

1. Coloque o cartão no Raspberry e ligue o robô.
2. A tela pequena mostra **"HEXAPOD · INICIANDO"** e vai marcando Sistema, Rede, ESP32 e Ponte.
3. **A primeira vez demora uns 2 minutos.** O robô ajusta o cartão e grava o programa do ESP32 sozinho. Não desligue nessa hora.
4. Depois a tela gira entre três páginas. Uma delas tem um **QR** e um **código de 5 letras e números**, como `K7F2Q`.

## 3. Parear o celular

1. Instale o app **Hexápode** (em breve na Google Play).
2. Abra o app e toque em **Parear um robô**.
3. **Aponte a câmera para o QR** da tela do robô, ou **digite o código de 5** que aparece ao lado dele.
4. O Android vai perguntar se quer conectar à rede **"Hexapode-…"**: toque em **Conectar**. Se aparecer uma lista, escolha a rede com o nome do seu robô.
5. Pronto: **"Pareado!"**.

O código muda a cada 10 minutos e a cada uso. Se o app disser "código errado ou vencido", use o que está na tela agora.

## 4. Wi-Fi de casa (opcional)

Sem configurar nada, o robô cria a **própria rede**, e o celular conecta nela. Isso funciona em qualquer lugar, até no quintal sem roteador. Para usar a rede de casa:

1. No app: **Ajustes → Rede do robô → Conectar a uma rede**.
2. Escolha a sua rede e digite a senha. Ela fica gravada **só no robô**.
3. Se a senha estiver errada, o robô **volta sozinho** para a rede dele, e o app avisa o motivo.

## 5. Acesso remoto (opcional)

Para pilotar fora de casa (4G, outra rede): **Ajustes → Acesso remoto**, passo a passo em [`acesso-remoto.md`](acesso-remoto.md).

## Se algo der errado

| O que acontece | O que fazer |
|---|---|
| A tela fica apagada ou "pisca" | Quase sempre é energia: troque a fonte ou o cabo |
| O app não acha o robô | Celular e robô precisam estar na mesma rede. Na tela "Não achei o robô", informe o IP que aparece na tela do robô |
| "Código errado ou vencido" | Use o código que está na tela **agora** (ele muda) |
| A rede "Hexapode-…" não aparece | O Wi-Fi do Raspberry não ligou: energia de novo. Espere 1 minuto depois de ligar |
| A tela mostra **"ESP32 sem resposta"** | Confira o cabo USB entre o Raspberry e o ESP32 |
