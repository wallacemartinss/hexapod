# CAD e geometria

Base mecânica: *Hexapod Spider Robot with Servo & Arduino*, de Emre Kalem (MakerWorld), com o corpo modificado para a eletrônica (`Body_eletronica`).

## Arquivos

Os STLs **não são versionados**: a licença do modelo (*Standard Digital File License*) não permite redistribuí-los. Ficam só na máquina, em `cad/stl/` (ignorada pelo git).

| Arquivo | Peça | De onde veio |
|---|---|---|
| `stl/Leg_A.stl` | Coxa (suporte do servo do fêmur) | MakerWorld |
| `stl/Leg_B.stl` | Fêmur (suporte do servo do joelho) | Extraída do `Hexapod_3MF.3mf` do MakerWorld |
| `stl/Leg_C.stl` | Tíbia (Leg_C_1 + Leg_C_2 numa peça) | MakerWorld |
| `stl/Body_eletronica.stl` | Corpo com os 6 servos da coxa | Modificação própria |

## Medir de novo

```bash
cd cad
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python measure_legs.py
```

O script encontra os eixos ajustando círculos nos furos do horn e do pino de cada servo, então só depende dos furos, não da posição das peças no arquivo.

## Medidas (18/10/2026)

| Medida | Valor | Como |
|---|---|---|
| Coxa: eixo da coxa → eixo do fêmur | **38,07 mm** | Leg_A: horn em y = −8,04; eixo do fêmur em y = 30,04 |
| Fêmur: eixo do fêmur → eixo do joelho | **86,27 mm** | Leg_B: horn em y = 45,97; pino em y = −40,31 |
| Tíbia: eixo do joelho → ponta do pé | **163,02 mm** | Leg_C: ponto mais distante do eixo do joelho |
| Desvio do pé | **18,54°** | A tíbia é curva: o pé fica 18,54° fora do eixo do suporte |
| Eixo do fêmur acima da face do horn da coxa | 15,04 mm | Leg_A |

Os furos batem com o MG996R: o encaixe tem 40 × 20 mm e o eixo fica a 10 mm da ponta do servo.

### Eixos da coxa no corpo

O hexágono **não é regular**: as pernas do meio ficam ~10 mm mais perto do centro.

| Perna | x (mm) | y (mm) | Raio (mm) | Ângulo de montagem |
|---|---|---|---|---|
| 0 dianteira esquerda | 100,99 | 57,15 | 116,0 | 29,5° (usado: 30°) |
| 1 meio esquerda | 0,00 | 105,78 | 105,8 | 90° |
| 2 traseira esquerda | −100,98 | 57,16 | 116,0 | 150,5° (usado: 150°) |
| 3 dianteira direita | 100,99 | −57,08 | 116,0 | −29,5° (usado: −30°) |
| 4 meio direita | 0,00 | −105,67 | 105,7 | −90° |
| 5 traseira direita | −100,98 | −57,07 | 116,0 | −150,5° (usado: −150°) |

Os ângulos usados são os nominais (múltiplos de 30°). A diferença de ~0,5° para a posição do furo, e de ~3° para o eixo do encaixe, é absorvida na calibração do horn de cada servo.

## Convenções (valem para o firmware)

- **Corpo:** origem no centro, **x para a frente**, y para a esquerda, z para cima. O plano z = 0 passa pelos eixos dos fêmures.
- **Frente = +x** (lado das pernas a ±30°). *A confirmar na montagem.*
- **Perna:** origem no eixo da coxa, x para fora no ângulo de montagem, z para cima.
- **Ângulos de junta (IK):**
  - coxa: 0 = apontando no ângulo de montagem; positivo = anti-horário visto de cima;
  - fêmur: 0 = horizontal; positivo = para cima;
  - tíbia: 0 = alinhada com o fêmur; negativo = dobrando para baixo (em pé fica perto de −110°).

A conversão de ângulo de junta para pulso de servo (sentido, offset do horn e o desvio de 18,54° do pé) fica no módulo `servo/`, com calibração gravada na NVS.
