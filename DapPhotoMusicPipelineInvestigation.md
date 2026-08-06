# 1. Resumo executivo

A fotografia não é apenas um seed arbitrário: ela controla diretamente root, escala, BPM, gate, waveform, registro e a ocupação da grade 16×8. A luminância espacial também influencia a atividade rítmica da Melody no Jam.

Mas a identidade fotográfica é apenas parcial e perde força depois da análise inicial:

- hue não determina diretamente uma tonalidade contínua;
- root é escolhido por amostragem ponderada e determinística usando um seed derivado dos pixels;
- cores não controlam posição temporal;
- o Jam recompõe a harmonia global;
- Bass e Harmony são fortemente quantizados;
- Melody usa templates, contornos e regras hardcoded;
- grooves e kits dependem principalmente do Vibe e dos UUIDs;
- o BPM da foto é descartado no Jam, que usa 96 BPM fixos.

Conclusão: o sistema atual produz uma assinatura musical fotográfica real, mas no Jam a foto funciona como material tonal/rítmico inicial submetido a uma reconstrução musical majoritariamente baseada em regras. A classificação mais precisa é:

> identidade perceptível moderada no Musical Photo; identidade perceptível fraca a moderada no resultado final da Jam.

Não é um resultado completamente arbitrário, mas também não preserva uma “impressão digital musical” forte e estável da fotografia.

# 2. Arquivos e tipos envolvidos

| Área | Arquivos principais | Responsabilidade |
|---|---|---|
| Entrada | [`CameraView.swift:364`](/Users/pedrolima/Documents/Academy%202026/DapNext/Dap/Features/Capture/CameraView.swift:364), `PhotoLibraryViewModel.swift:109` | Captura/importação de `Data` |
| Preparação visual | [`PhotoMusicPipeline.swift:114`](/Users/pedrolima/Documents/Academy%202026/DapNext/Dap/Services/PhotoMusicPipeline.swift:114) | Decode, orientação, normalização e análise de cor |
| Cor e Cover | [`RetroCoverRenderer.swift:70`](/Users/pedrolima/Documents/Academy%202026/DapNext/Dap/Services/RetroCoverRenderer.swift:70) | Cores canônicas, paleta e halftone |
| Modelo musical | [`PhotoSound.swift:69`](/Users/pedrolima/Documents/Academy%202026/DapNext/Dap/Models/PhotoSound.swift:69) | `MusicHarmony`, `MusicNote`, `MusicSequence`, `SoundProfile` |
| Sequência fotográfica | [`PhotoMusicPipeline.swift:414`](/Users/pedrolima/Documents/Academy%202026/DapNext/Dap/Services/PhotoMusicPipeline.swift:414) | Root, escala, BPM, notes e fallback |
| Metadados semânticos | [`PhotoMetadataGenerator.swift:75`](/Users/pedrolima/Documents/Academy%202026/DapNext/Dap/Services/PhotoMetadataGenerator.swift:75) | Vision e Foundation Models |
| Seleção de Jam | [`JamAssignments.swift:27`](/Users/pedrolima/Documents/Academy%202026/DapNext/Dap/Features/Jam/JamAssignments.swift:27) | Slots Bass/Harmony/Melody/reserve |
| Arranjo | [`JamArrangementBuilder.swift:42`](/Users/pedrolima/Documents/Academy%202026/DapNext/Dap/Features/Jam/JamArrangementBuilder.swift:42) | Harmonia global, papéis, Vibe, transformação das notas |
| Groove | [`JamGrooveLibrary.swift:12`](/Users/pedrolima/Documents/Academy%202026/DapNext/Dap/Features/Jam/JamGrooveLibrary.swift:12) | Grooves hardcoded e variações por UUID |
| Vibe e playback | [`JamView.swift:1624`](/Users/pedrolima/Documents/Academy%202026/DapNext/Dap/Features/Jam/JamView.swift:1624) | Rebuild e encaminhamento para playback |
| Renderização de áudio | [`JamAudioRenderer.swift:58`](/Users/pedrolima/Documents/Academy%202026/DapNext/Dap/Services/JamAudioRenderer.swift:58) | Síntese, samples, drums e mix |
| Runtime | [`MusicPlayer.swift:301`](/Users/pedrolima/Documents/Academy%202026/DapNext/Dap/Services/MusicPlayer.swift:301) | Loop, buffer e transição no próximo ciclo |
| Export | [`JamStoryAudioRenderer.swift:27`](/Users/pedrolima/Documents/Academy%202026/DapNext/Dap/Features/Jam/Export/JamStoryAudioRenderer.swift:27) | Renderização offline do áudio exportado |

# 3. Diagrama completo do pipeline

```text
AVCapturePhoto / PhotosPickerItem / demo image
  ↓
Data
  ↓
PhotoLibraryViewModel.importPhotoData()
PhotoLibraryViewModel.importPhotos()
OnboardingView.startPhotoPreparation()
  ↓
PhotoMusicPipeline.prepare(imageData:)
  ↓
UIImage(data:)
  ↓
normalizedCGImage(from:maximumDimension:)
  - aplica orientação da UIImage
  - preserva proporção
  - limita maior dimensão a 1024 px
  - desenha em CGColorSpaceCreateDeviceRGB()
  ↓
analysisInputData: PNG do CGImage normalizado
  ↓
analyzeColor(cgImage:)
  ├─ raster 64×64 RGBA
  ├─ média RGB
  ├─ hue médio
  ├─ saturação média
  ├─ luminância média
  ├─ hue samples com saturação ≥ 0.10
  ├─ variância circular do hue
  ├─ Sobel edge density
  ├─ 12 weighted hue bins
  └─ FNV selectorSeed dos bytes RGBA
       ↓
selectRootPitchClass(...)
  - bins ponderados
  - softening exponent 0.85
  - fallback residual 0.003
  - seleção determinística pelo seed
       ↓
PhotoMusicColorProfile
  ↓
RetroCoverRenderer.tonalPalette(for:)
  - root pitch class
  - quatro cores canônicas
  ↓
RetroCoverRenderer.patternHalftone(...)
  - luminância da imagem
  - quatro tons
  - matriz clustered-dot 4×4
  ↓
PreparedPhotoInput
  - originalImageData
  - analysisInputData
  - processedPreviewData
  - colorProfile
  ↓
PhotoMusicPipeline.process(prepared:)
  ↓
analyzeTones(cgImage:)
  ├─ análise de tons em imagem até 256 px
  ├─ quatro tone bins
  ├─ significantToneCount
  └─ grade tonal 16×8
       ↓
buildSequence(...)
  ├─ root
  ├─ scale
  ├─ BPM
  ├─ octaveRange
  ├─ gate
  ├─ waveform
  ├─ MusicNote por célula não-zero
  └─ fallback motif, se necessário
       ↓
MusicSequence
  ├─ MusicHarmony
  ├─ [MusicNote]
  └─ SoundProfile
       ↓
UUID + PhotoSound + Cover PNG
       ↓
PhotoStore.save()
       ↓
PhotoLibraryViewModel.items
       ↓
Vision + Foundation Models
  - somente name/description
  - não altera MusicSequence
       ↓
JamView
  ↓
JamSlotAssignments
  - Bass
  - Harmony
  - Melody
  - reserve
       ↓
JamArrangementBuilder
  ├─ globalHarmony()
  ├─ interpolatedPreset(Vibe)
  ├─ JamGrooveLibrary.pattern()
  ├─ Bass transformation
  ├─ Harmony transformation
  └─ Melody Motif Engine
       ↓
JamArrangement
  ├─ MusicSequence combinada
  ├─ activeStepsBySoundID
  └─ MusicPercussionPattern
       ↓
PhotoLibraryViewModel.playTransientSequence(loops: true)
       ↓
MusicPlayer.playJam()
       ↓
JamAudioRenderer.render(loops: true)
  ├─ Future Bass
  ├─ Harmony samples/procedural fallback
  ├─ Melody samples/procedural fallback
  ├─ kick ducking
  ├─ drum samples/procedural fallbacks
  └─ clamp final
       ↓
AVAudioPCMBuffer
       ↓
jamPlayerNode
  ↓
LFO mixer → Delay → Reverb → main mixer
       ↓
áudio tocado na Jam

Alteração de Vibe/Kits/Arrange
  ↓
new JamArrangement
  ↓
MusicPlayer.enqueueLoopReplacement()
  - debounce 135 ms
  - latest wins
  - troca no próximo loop
```

A fotografia deixa de influenciar diretamente o fluxo quando o `PhotoSound.sequence` já foi criado. A partir daí, o Jam usa apenas a sequência, os UUIDs das fotos e o estado persistido do Jam.

# 4. Explicação etapa por etapa

## 4.1 Entrada, orientação e normalização

A captura e o import fornecem apenas `Data`. O pipeline decodifica esse dado com `UIImage`, redesenha a imagem e aplica a orientação antes da análise.

A maior dimensão é limitada a 1024 pixels. Não existe crop automático: a proporção original é mantida, embora as análises de cor e tom desenhem a imagem em grades fixas, incluindo 64×64 e 16×8.

A imagem original não é persistida no `PhotoSound`. O `originalImageData` sobrevive apenas durante o refinamento de metadados.

Referência: [`PhotoMusicPipeline.swift:120`](/Users/pedrolima/Documents/Academy%202026/DapNext/Dap/Services/PhotoMusicPipeline.swift:120), [`PhotoSound.swift:260`](/Users/pedrolima/Documents/Academy%202026/DapNext/Dap/Models/PhotoSound.swift:260).

## 4.2 Análise de cor

O raster de 64×64 produz:

- média RGB;
- hue médio;
- saturação média;
- luminância média;
- lista de hues cromáticos;
- variância circular de hue;
- densidade de bordas;
- histogramas de hue em 12 bins;
- seed FNV.

O hue médio não é a média circular dos hues individuais. Ele é obtido depois de calcular a média RGB da imagem e aplicar `hsb` nesse RGB médio. Em imagens com cores opostas, isso pode gerar baixa saturação e hue pouco representativo.

A saturação usada é do tipo HSV/HSB:

```text
saturation = (maxRGB - minRGB) / maxRGB
```

Não há HSL.

A luminância usa:

```text
0.2126 × R + 0.7152 × G + 0.0722 × B
```

A variância de hue utiliza apenas pixels com saturação mínima de 0.10.

## 4.3 Root pitch class

O root não é escolhido diretamente como:

```text
root = floor(hue / 30)
```

Essa função existe em `RetroCoverRenderer.pitchClass(forHueDegrees:)`, mas é usada pelo preview da câmera, não pelo pipeline final.

No pipeline final:

1. cada pixel cromático contribui para um bin de 30°;
2. a contribuição é ponderada por saturação, luminância e alpha;
3. os pesos são suavizados com `pow(weight, 0.85)`;
4. é adicionado um peso residual de 0.003;
5. o seed seleciona deterministicamente uma posição dentro da distribuição acumulada.

Portanto, a relação ativa é:

```text
distribuição de hue → distribuição de possíveis roots → escolha determinística pelo seed
```

Não é uma correspondência contínua nem uma escolha garantida da cor dominante.

O mapeamento dos bins usa índices cromáticos:

```text
0 → C
1 → C♯
2 → D
...
11 → B
```

O círculo das quintas aparece na etapa inversa, na paleta canônica de cores dos pitch classes. Ele não governa a seleção do root a partir da foto.

Referências: [`PhotoMusicPipeline.swift:304`](/Users/pedrolima/Documents/Academy%202026/DapNext/Dap/Services/PhotoMusicPipeline.swift:304), [`PhotoMusicPipeline.swift:623`](/Users/pedrolima/Documents/Academy%202026/DapNext/Dap/Services/PhotoMusicPipeline.swift:623), [`RetroCoverRenderer.swift:70`](/Users/pedrolima/Documents/Academy%202026/DapNext/Dap/Services/RetroCoverRenderer.swift:70).

## 4.4 Escala

A escala é escolhida assim:

```text
hueVariance > 70°        → whole tone
30° ≤ hueVariance ≤ 70°  → dorian
hueVariance < 30°:
    saturation ≥ 0.45    → major pentatonic
    saturation < 0.45    → minor pentatonic
```

A diversidade cromática, portanto, muda a família da escala, mas não as notas individualmente de maneira contínua.

A versão dessaturada de uma foto tende a:

- perder confiabilidade cromática;
- cair em `minorPentatonic`;
- escolher root principalmente pelo seed;
- ainda preservar informação tonal de luminância.

## 4.5 Tone analysis e grade 16×8

A imagem é analisada em dois tamanhos:

- imagem reduzida até 256 px para `significantToneCount`;
- grade fixa de 16×8 para as notas.

A luminância passa por:

```text
contraste × 1.12
shadow bias
clamp 0...1
```

Depois é convertida em quatro níveis:

```text
floor(normalizedLuminance × 4)
```

Os níveis são 0, 1, 2 e 3.

Na sequência normal:

- nível 0 = rest;
- nível 1 = velocity aproximadamente 0.33;
- nível 2 = velocity aproximadamente 0.67;
- nível 3 = velocity 1.0.

Cada célula não-zero gera uma `MusicNote`. Assim, uma foto pode produzir desde poucas notas até 128 notas, uma por célula da grade.

A posição espacial da luminância é diretamente musical:

- coluna → step;
- linha → registro/pitch offset;
- intensidade tonal → velocity;
- célula vazia → rest.

A posição espacial das cores, entretanto, não é usada diretamente.

## 4.6 BPM, gate, registro e waveform

O BPM da Musical Photo é:

```text
70 + luminance × 70
```

com clamp entre 70 e 140.

O gate vem da densidade de bordas Sobel:

```text
edgeDensity ≤ 0.03 → gate 0.98
edgeDensity ≥ 0.25 → gate 0.25
```

Entre esses valores, a interpolação é linear.

O `octaveRange` depende do número de níveis tonais significativos:

```text
4 níveis significativos ou mais → 2 oitavas
3 níveis                    → 1.5 oitava
caso contrário              → 1 oitava
```

O waveform depende do hue médio:

```text
90° ≤ hue < 300° → square
caso contrário   → triangle
```

Esse waveform tem influência forte na reprodução standalone, mas fraca na Jam, pois Bass usa Future Bass e Harmony/Melody preferem samples.

Referência: [`PhotoMusicPipeline.swift:429`](/Users/pedrolima/Documents/Academy%202026/DapNext/Dap/Services/PhotoMusicPipeline.swift:429).

## 4.7 Construção da `MusicSequence`

As notas normais são construídas por:

```text
midi = 60 + root + pitchOffset(row, scale, octaveRange)
```

A linha 0 da grade representa registros mais altos; a linha 7, mais baixos.

A `MusicNote` contém:

```text
step
row
midiNote
velocity
voiceRole opcional
timingOffsetSteps opcional
```

Não existe duração individual por nota.

A duração standalone é essencialmente:

```text
stepDuration × gate
```

No Jam, a duração é reinterpretada pelo renderer por papel musical.

## 4.8 Cover

O Cover não conserva as cores originais da foto. Ele usa:

1. luminância espacial da imagem;
2. root pitch class;
3. quatro cores canônicas derivadas do root;
4. quantização de quatro tons;
5. matriz clustered-dot 4×4.

Portanto:

- textura, formas e contraste espacial permanecem parcialmente;
- hue original é substituído pela paleta canônica do root;
- duas fotos diferentes com luminância semelhante podem gerar Covers visualmente parecidos se o root coincidir.

As funções Floyd–Steinberg e `recolor` existem, mas não são usadas pelo caminho ativo atual.

Referência: [`RetroCoverRenderer.swift:93`](/Users/pedrolima/Documents/Academy%202026/DapNext/Dap/Services/RetroCoverRenderer.swift:93).

## 4.9 Metadados semânticos

Vision classifica até cinco labels com confiança mínima de 0.12. Foundation Models recebe:

- labels visuais;
- root;
- escala;
- BPM;
- waveform;
- hint de luminância.

O resultado é apenas `name` e `description`. Ele não altera:

- root;
- escala;
- notas;
- ritmo;
- Jam;
- playback.

Referências: [`PhotoMetadataGenerator.swift:64`](/Users/pedrolima/Documents/Academy%202026/DapNext/Dap/Services/PhotoMetadataGenerator.swift:64), [`PhotoLibraryViewModel.swift:277`](/Users/pedrolima/Documents/Academy%202026/DapNext/Dap/Features/Gallery/PhotoLibraryViewModel.swift:277).

# 5. Tabela visual → musical

| Característica visual | Etapa do código | Valor intermediário | Decisão musical afetada | Intensidade da influência | Observações |
|---|---|---|---|---|---|
| Hue médio | `analyzeColor` | `PhotoMusicColorProfile.hue` | Waveform; indiretamente escala/root | indireta | Calculado a partir do RGB médio, não da média circular dos pixels |
| Hue por pixel | `analyzeColor` | `hueBins[12]` | Root pitch class | direta | Bins rígidos de 30° |
| Distribuição de hue | `analyzeColor` | Pesos dos 12 bins | Probabilidade ponderada do root | direta | Não escolhe necessariamente a cor dominante |
| Saturação média | `analyzeColor` | `saturation` 0...1 | Major/minor pentatonic; fallback scale | direta | Threshold rígido em 0.45 |
| Saturação por pixel | `analyzeColor` | `saturationWeight` | Peso dos bins de hue | indireta | Usa potência 2.0 |
| Luminância média | `analyzeColor` | `luminance` 0...1 | BPM 70...140 | direta | No Jam o BPM é substituído por 96 |
| Luminância espacial | `analyzeTones` | Grade 16×8 de níveis 0...3 | Steps, rests, rows, MIDI e velocity | direta | É a maior fonte de estrutura fotográfica |
| Contraste | `normalizedToneAnalysisLuminance` e Sobel | Não há feature `contrast` persistida | Notes, velocities e gate | indireta | Não existe medição independente de contraste |
| Bordas/detalhes | `sobelEdgeDensity` | `edgeDensity` | Gate | direta | Mais bordas → gate menor |
| Diversidade cromática | `circularVarianceDegrees` | Variância circular em graus | Whole tone, Dorian ou pentatônica | direta | Thresholds de 30° e 70° |
| Proporção entre cores | `hueBins` | Peso cromático por bin | Root | direta | Saturação e luminância também alteram o peso |
| Posição espacial das cores | Não há | Nenhum | Nenhum diretamente | sem influência | Só a posição da luminância entra nos steps |
| Posição espacial da luminância | `toneLevels` | `row × step` | Distribuição temporal e registro | direta | Preservada em baixa resolução |
| Paleta com poucas cores | `hueVariance`, `hueBins` | Variância e pesos | Escala e root | direta/indireta | Número de cores únicas não é medido explicitamente |
| Conteúdo semântico | Vision/Foundation Models | Labels, name, description | Nenhuma decisão musical | sem influência | Metadados somente |
| Orientação EXIF | `normalizedCGImage` | CGImage orientado | Pode alterar grade espacial | direta na entrada | A orientação é aplicada antes da análise |
| Crop | Não há crop próprio | Área visível recebida | Todas as features derivadas | indireta | Alterações de crop mudam amostras e grade |
| Resolução | Normalização e downsampling | Raster até 1024, 256, 64 e 16×8 | Todas as features | indireta | Resoluções diferentes podem gerar pixels normalizados diferentes |
| Alpha | `analyzeColor`/`toneLevels` | Alpha por pixel | Cor/root e tons | indireta | Há tratamento diferente entre análise de cor e tons |
| Espaço de cor | `CGColorSpaceCreateDeviceRGB()` | RGB convertido pelo Core Graphics | Todas as features cromáticas | impossível determinar completamente | Não há política explícita para sRGB versus Display P3 |
| Bytes do raster | `stableSelectorSeed` | UInt64 FNV | Root e fallbacks | apenas seed | Pequenas alterações podem produzir grande alteração no seed |
| UUID da foto | Jam | `PhotoSound.id` | Groove, roles em empate, variações | apenas seed | Não é derivado da imagem; é UUID aleatório |

# 6. Tabela de origem dos parâmetros musicais

| Parâmetro musical | Origem | Depende da foto? | Depende do seed? | Depende do Vibe? | Regra ou arquivo responsável |
|---|---|---:|---:|---:|---|
| Root | Weighted hue bins + seed | Sim | Sim | Não | `PhotoMusicPipeline.selectRootPitchClass` |
| Scale | Hue variance + saturation | Sim | Não normalmente | Não na foto; sim no Jam via recomposição | `PhotoMusicPipeline.musicScale`, `JamArrangementBuilder.globalHarmony` |
| Pitch classes standalone | Root, escala, row e octave range | Sim | Só em fallback | Não | `PhotoMusicPipeline.pitchOffset` |
| Pitch classes no Jam | Histograma dos notes ativos + global harmony | Sim indiretamente | Sim nas variações | Sim indiretamente | `JamArrangementBuilder.globalHarmony` |
| BPM standalone | Luminância média | Sim | Não | Não | `PhotoMusicPipeline.safeBPM` |
| BPM na Jam | Constante 96 | Não | Não | Não | `JamView.jamBPM` |
| Octave range | Número de tone levels significativos | Sim | Não | Não diretamente | `PhotoMusicPipeline.octaveRange` |
| Registro Bass | Regras 48...72 + register shift | Indiretamente | Variações usam seed | Sim | `JamArrangementBuilder.bassMIDINote` |
| Registro Harmony | Source notes + escala global + center | Sim | Variações usam seed | Sim | `buildLegacyHarmonyNotes` |
| Registro Melody | Source notes, anchor, contour e register plan | Sim | Sim | Sim | Melody Motif Engine |
| Note duration standalone | Gate global | Sim via edge density | Não | Não | `SoundProfile.gate`, `JamAudioRenderer` |
| Note duration Bass | Mínimo de 96% de um step | Indireta | Não | Gate tem floor | `JamAudioRenderer.renderFutureBassLine` |
| Note duration Harmony | Máximo entre gate e 75% de step | Indireta | Não | Sim parcialmente | `effectiveMelodicEndFrame` |
| Note duration Melody | Gate + fade | Indireta | Não | Sim | `effectiveMelodicEndFrame` |
| Velocity standalone | Tone level / 3 | Sim | Não | Não | `PhotoMusicPipeline.buildSequence` |
| Velocity Bass | Source velocity × accents de papel | Sim | Sim nas variações | Sim | `buildBassNotes` |
| Velocity Harmony | Source velocity × multiplicador | Sim | Sim nas variações | Sim | `buildHarmonyNotes` |
| Velocity Melody | Source velocity × attack role × seed | Sim | Sim | Sim | `melodyVelocity` |
| Rest probability | Não existe | Não como probabilidade | Não | Não | Rest ocorre quando tone level é zero |
| Rhythmic density standalone | Quantidade de células não-zero | Sim | Não | Não | Grade tonal |
| Rhythmic density no Jam | Source count × preset density × role multiplier | Sim | Não normalmente | Sim | `effectiveDensity` |
| Accents | Tone level ou regras de papel | Sim | Sim no Jam | Sim indiretamente | `bassVelocityMultiplier`, `melodyVelocity` |
| Track role | Registro médio, quantidade de notes e UUID | Sim indiretamente | Sim em empate | Não | `assignRoles` |
| Groove | Templates hardcoded | Não | UUIDs ativos | Sim | `JamGrooveLibrary.pattern` |
| Kit | Seleção manual ou Auto por região | Não | Não | Sim no Auto | `JamView.resolvedDrumKit` |
| Arrangement | Roles, notes, global harmony, Vibe e variations | Sim | Sim | Sim | `JamArrangementBuilder` |
| Vibe | Estado persistido/interação do usuário | Não | Não | É o próprio parâmetro | `JamSessionState`, `JamView` |
| Effects | Estado do Jam | Não | Não | Não | `MusicPlayer.applyJamSettings` |
| Export de áudio | Arrangement + percussion | Sim via arrangement | Sim via arrangement | Sim via arrangement | `JamStoryAudioRenderer` |
| Efeitos no export | Snapshot contém settings, renderer não os aplica | Não | Não | Não | `JamStoryAudioRenderer` ignora `effectSettings` |

# 7. Análise de determinismo

## 7.1 A mesma imagem gera sempre a mesma sequência?

Para a mesma imagem decodificada nos mesmos pixels normalizados, sim, a `MusicSequence` é determinística.

O `UUID()` e `createdAt: .now` são criados ao montar `PhotoSound`, mas não entram na sequência fotográfica.

Porém, isso não significa que a mesma imagem produza sempre a mesma Jam:

- cada processamento recebe um UUID diferente;
- UUIDs participam dos grooves;
- UUIDs participam de seeds de variação;
- UUIDs resolvem empates de role assignment;
- o conjunto de UUIDs influencia a Melody.

Logo:

```text
mesma imagem → mesma MusicSequence
mesma imagem recriada como novo PhotoSound → Jam potencialmente diferente
```

Referência: [`PhotoMusicPipeline.swift:229`](/Users/pedrolima/Documents/Academy%202026/DapNext/Dap/Services/PhotoMusicPipeline.swift:229).

## 7.2 Valores usados no seed da foto

O `selectorSeed` é um FNV-1a-like hash dos bytes RGBA do raster de 64×64 após normalização.

Ele não usa diretamente:

- Data JPEG/PNG original;
- nome do arquivo;
- `Date`;
- UUID;
- metadados EXIF;
- conteúdo semântico.

Ele usa indiretamente características visuais porque o raster deriva delas.

O seed controla:

- escolha do root;
- motif de fallback;
- registro do fallback;
- posição-alvo do fallback;
- em seguida, no Jam, influencia transformações derivadas.

## 7.3 Seeds do Jam

A Melody usa:

- UUIDs ativos ordenados;
- root global;
- escala global;
- região do Vibe;
- notes transformadas;
- geração da variação.

Bass e Harmony usam:

- UUID da foto;
- papel;
- intenção;
- geração;
- root e escala globais;
- região;
- steps e MIDI das source notes.

Grooves usam apenas o conjunto ordenado de UUIDs e a região do Vibe.

Não foram encontrados `Hasher`, `hashValue`, `Random`, `Date` ou aleatoriedade de runtime no algoritmo musical.

## 7.4 Pequenas mudanças

O comportamento é híbrido:

- BPM muda de maneira relativamente contínua;
- edge density muda de maneira relativamente contínua;
- tone levels mudam abruptamente ao cruzar limites;
- escala muda abruptamente em 30°/70° de variância ou 0.45 de saturação;
- root pode mudar abruptamente porque o seed muda por avalanche;
- o resultado da Melody pode mudar quando o `registerShift` arredondado cruza um inteiro;
- região e groove mudam abruptamente nos limites do Vibe.

A estabilidade a pequenas mudanças é, portanto, baixa a moderada.

## 7.5 Dependências externas

A análise é determinística no código, mas depende de:

- comportamento de decode da `UIImage`;
- downsampling do Core Graphics;
- conversão para `DeviceRGB`;
- disponibilidade dos samples no bundle;
- versão do sistema e algoritmos de renderização de imagem.

Não há versão do algoritmo persistida junto ao Musical Photo. A constante `colorPipelineAlgorithmVersion = 2` existe, mas não é usada nem persistida.

# 8. Análise dos fallbacks

| Condição | Fallback | Resultado |
|---|---|---|
| Imagem não decodifica | `decodeFailed` | Criação falha; não há sequência |
| CGContext não é criado | Erro de decode/render | Criação falha |
| Peso alpha total zero | Perfil com hue/sat/lum/edge zero e root C | Pode cair em fallback posterior |
| Nenhum peso cromático | 12 pesos iguais | Root escolhido pelo seed |
| Imagem dessaturada | `hueVariance = 0`; escala por saturação | Normalmente minor pentatonic |
| Imagem preto e branco | Sem hue confiável; root seed-based | Luminância ainda gera notes |
| Imagem preta | Tone grid tende a ser toda zero | Motif fallback de cinco notes |
| Imagem branca | Tone grid tende a ser toda nível 3 | Até 128 notes, não fallback |
| Tone analysis falha | `gridLevels = []` | Fallback de cinco notes |
| Tone grid vazia | Fallback de cinco notes | Steps 0, 3, 6, 10 e 14 |
| Perfil inválido | Root/scale/gate/register seguros | Fallback determinístico |
| Fallback de root confiável | Mantém root cromático parcial | Não ignora completamente a cor |
| Fallback sem root confiável | `seed % 12` | Root puramente seed-based |
| Fallback de escala | Saturação ≥ 0.45 major; caso contrário minor | Não usa variância de hue |
| Fallback de octave | 1 oitava | Registro limitado |
| Fallback de gate | Gate entre 0.45 e 0.82 | Evita extremos |
| Fallback de waveform | Triangle | Ignora hue |
| Sample de Harmony/Melody ausente | Procedural waveform | Playback continua |
| Sample de drum ausente | Kick/snare/closed hat procedural | Rim ausente é ignorado |
| Photo sem notes no Jam | Não ocupa role ativa | Pode permanecer em reserve |
| Arrangement sem notes | `nil` | Jam não inicia playback |
| Kit Auto | Kit derivado da região Vibe | Não depende da imagem |

O fallback mais desconectado da imagem é o de root para imagens sem cromaticidade: uma foto monocromática pode receber qualquer pitch class baseada nos bytes do raster.

Outro caso importante é a imagem branca: ela não cai no motif fallback. Como o nível tonal máximo é considerado ativo, tende a produzir uma grade extremamente densa.

# 9. Problemas e riscos encontrados

## Influência fotográfica

1. O root não é uma função contínua do hue. É uma seleção ponderada por seed.
2. Fotos visualmente próximas podem receber roots diferentes.
3. A posição espacial das cores é ignorada.
4. A distribuição espacial da luminância é preservada apenas em 16×8.
5. Conteúdo semântico não participa da música.
6. O BPM da foto não sobrevive no Jam.
7. A escala original da foto não sobrevive diretamente ao `globalHarmony` do Jam.
8. Dorian e whole tone podem ser reduzidos a major/minor pentatonic no arranjo global.

## Thresholds e quantizações

Os principais valores hardcoded estão em [`PhotoMusicPipeline.swift:48`](/Users/pedrolima/Documents/Academy%202026/DapNext/Dap/Services/PhotoMusicPipeline.swift:48):

- análise 64×64;
- saturação mínima 0.10;
- variância 30°/70°;
- tone fraction 0.05;
- edge threshold 0.18;
- edge density 0.03/0.25;
- gate 0.25/0.98;
- tone analysis máximo 256;
- softening exponent 0.85;
- hue fallback ratio 0.003.

Esses valores criam mudanças discretas e não têm documentação de calibração no código.

## Cor e alpha

`analyzeColor` lê os canais RGBA do contexto premultiplied-last sem desfazer explicitamente o premultiplication antes de acumular RGB. `toneLevels`, por outro lado, divide RGB pelo alpha.

Para imagens transparentes ou parcialmente transparentes, as duas análises podem interpretar a cor de maneira diferente.

## Espaço de cor

Todos os contextos usam `CGColorSpaceCreateDeviceRGB()`. Não existe política explícita para:

- sRGB;
- Display P3;
- extended sRGB;
- preservação de ICC profile.

Não é possível confirmar por inspeção estática exatamente como cada imagem Display P3 será convertida em todos os dispositivos.

## Contraste e normalização

O sistema usa três tratamentos diferentes:

- luminância direta na análise de cor;
- luminância com ajuste de contraste na análise tonal;
- luminância com ajuste de contraste no Cover.

Isso significa que BPM, notes e Cover podem responder de forma diferente à mesma alteração de exposição/contraste.

## Código legado e duplicação

- `RetroCoverRenderer.floydSteinberg` e `recolor` permanecem no código, mas o pipeline ativo usa `patternHalftone`.
- `RetroCoverRenderer.pitchClass(forHueDegrees:)` é usado no preview de câmera, não na geração final.
- `colorPipelineAlgorithmVersion` está declarado, mas não participa do resultado.
- A lógica de cálculo de hue existe tanto no pipeline quanto no preview da câmera.
- O `JamArrangementBuilder` concentra mais de 2200 linhas e mistura regras atuais, caminhos legacy, motifs, variações e sanitização.

## Jam

- A Melody é o papel mais fotográfico.
- Bass é reduzido principalmente a root/fifth, baixa oitava e padrão de steps.
- Harmony reduz a fonte a eventos e voicings globais.
- Groove não usa a imagem; usa Vibe e UUIDs.
- Trocar a mesma foto por uma nova instância pode trocar groove e variações por causa do UUID.
- O Vibe tem interpolação contínua para density/register/gate, mas templates, região e grooves são discretos.
- Há uma inconsistência de fronteira: `JamGrooveLibrary` usa `x <= 0.5`, enquanto a UI considera `x >= 0.5` como lado direito.
- Durante o drag, o áudio é atualizado principalmente ao cruzar quadrantes; a posição contínua final é aplicada ao terminar.

## Export

`JamStoryExportSnapshot` carrega `effectSettings`, mas `JamStoryAudioRenderer` chama `JamAudioRenderer` apenas com sequência e percussão. O áudio exportado não recebe:

- Reverb;
- Delay;
- LFO/tremolo.

Assim, o áudio exportado pode ser diferente do áudio ouvido na Jam.

Referências: [`JamStoryExportSnapshot.swift:52`](/Users/pedrolima/Documents/Academy%202026/DapNext/Dap/Features/Jam/Export/JamStoryExportSnapshot.swift:52), [`JamStoryAudioRenderer.swift:37`](/Users/pedrolima/Documents/Academy%202026/DapNext/Dap/Features/Jam/Export/JamStoryAudioRenderer.swift:37).

## Custo

Há uma rodada extra:

```text
CGImage normalizado
→ PNG analysisInputData
→ UIImage
→ CGImage novamente
```

Além disso, a imagem é rasterizada separadamente para:

- cor 64×64;
- tom até 256 px;
- grade 16×8;
- Cover até 1024 px;
- Vision.

Não há medição nesta investigação, portanto o impacto de performance não foi quantificado.

# 10. Avaliação perceptiva

| Cenário | Comportamento esperado |
|---|---|
| Mesma foto com pequena mudança de exposição | BPM muda gradualmente, mas tone levels, edge density e seed podem mudar. Root e notes podem sofrer mudança abrupta |
| Mesmo crop com pequena alteração de crop | Alteração da amostragem 64×64/16×8; steps e root podem mudar |
| JPEG versus PNG | Se os pixels normalizados forem idênticos, sequência igual. Compressão JPEG normalmente altera pixels, seed e thresholds |
| Foto colorida versus dessaturada | Perde informação de hue/variância; tende a minor pentatonic e root seed-based; luminância e grade podem permanecer parecidas |
| Duas fotos visualmente parecidas | Podem compartilhar BPM/escala/grade, mas ainda divergir em root por seed e em Jam por UUID |
| Duas fotos diferentes com média de cor semelhante | Podem ter root semelhante, mas distribuição de hue, tone grid, bordas e seed diferentes |
| Imagem de uma única cor preta | Fallback de cinco notes, root seed-based |
| Imagem de uma única cor branca | Grade provavelmente cheia, com muitas notes repetidas |
| Imagem dividida entre duas cores | Se as luminâncias forem iguais, posição das cores não afeta os steps; afeta root/variância/seed |
| Gradiente suave | Produz níveis tonais ordenados, mas quantizados em quatro bins; mudanças perto dos limites são abruptas |
| Imagem com muitos detalhes/ruído | Downsampling reduz parte do detalhe; Sobel aumenta edge density e encurta gate; seed continua extremamente sensível aos pixels |

A fotografia deixa uma assinatura mais estável em:

- luminância média;
- padrão geral de luminância em 16×8;
- densidade de bordas;
- distribuição ampla de hue.

Ela deixa uma assinatura menos estável em:

- root;
- grooves;
- variações de Melody;
- role assignment em empates;
- resultado final do Jam após Vibe.

# 11. Hipóteses futuras

| Hipótese | Problema resolvido | Benefício esperado | Risco musical | Risco técnico | Complexidade |
|---|---|---|---|---|---|
| Hue → tonalidade contínua combinando círculo cromático e círculo das quintas | Root atual é uma amostragem seed-based | Relação cor→nota mais explicável e reconhecível | Pode gerar pouca variedade ou tonalidades previsíveis demais | Necessita definir mapeamento e compatibilidade com Photos existentes | média |
| Luminância → registro e saturação → energia/densidade | Saturação hoje afeta quase apenas escala | Brilho, cor e energia teriam papéis audíveis distintos | Fotos claras podem ficar agudas/densas demais | Recalibração de limites e prevenção de saturação | baixa/média |
| Contraste/edge density → variação rítmica, accents e rests | Contraste hoje afeta principalmente gate | Textura visual poderia produzir ritmo mais perceptível | Ruído visual pode virar ritmo excessivo | Requer separar detalhe estrutural de ruído | média |
| Distribuição espacial de cores → steps e cores secundárias → notas complementares | Posição das cores não influencia a música | A composição visual teria assinatura temporal | Maior risco de conflito harmônico e excesso de notes | Necessita paleta/harmonia secundária consistente | média/alta |
| Assinatura estável com continuidade e hysteresis | Pequenas mudanças podem trocar root/motif abruptamente | JPEG, exposição e crop produziriam mudanças mais suaves | Reduz diversidade e surpresa | Exige persistir features/versão do algoritmo e definir continuidade | média/alta |

# 12. Avaliação final e recomendação para a versão 1.0

| Critério | Nota | Justificativa |
|---|---:|---|
| Determinismo | 4/5 | Sequência é determinística para pixels normalizados; Jam também é determinístico para os mesmos UUIDs e estado |
| Estabilidade a pequenas mudanças | 2/5 | Seed FNV, thresholds e bins rígidos podem produzir mudanças abruptas |
| Diversidade de resultados | 4/5 | Há variação por foto, Vibe, roles, UUIDs e motifs |
| Relação perceptível com a fotografia | 2/5 | Luminância e tonalidade influenciam, mas cor espacial, semântica e grande parte do ritmo são descartadas |
| Coerência musical | 4/5 | Escalas restritas, harmonia global, voicings e papéis produzem resultado consistente |
| Clareza conceitual | 3/5 | A arquitetura é rastreável, mas root seed-based, legacy paths e regras duplicadas dificultam a explicação |
| Explicabilidade para o usuário | 2/5 | O usuário vê root/escala/BPM, mas não há correspondência clara entre aspectos visuais e som |
| Facilidade de manutenção | 3/5 | Ownership é razoável, mas o builder é grande, há muitos magic numbers e não há testes documentados |
| Adequação para versão 1.0 | 3/5 | É uma base funcional e musicalmente coerente, mas a promessa de transformar a identidade da foto ainda é apenas parcialmente cumprida |

## Recomendação

**Revisar parcialmente.**

Não há evidência suficiente para recomendar um redesenho completo: o pipeline é determinístico, possui uma separação clara de responsabilidades e gera música coerente.

A revisão deveria concentrar-se em:

- tornar root e escala mais explicáveis;
- reduzir dependência arbitrária do seed;
- melhorar estabilidade a pequenas alterações;
- dar influência audível à distribuição espacial das cores;
- preservar mais material fotográfico na Melody e, se desejado, nos demais papéis;
- decidir explicitamente se o BPM da foto deve sobreviver no Jam;
- alinhar o áudio ouvido com o áudio exportado;
- registrar versão do algoritmo e calibrar os thresholds.

Não foram feitas alterações, commits, builds, testes, execuções no Simulator, profiling ou validação de escuta.
