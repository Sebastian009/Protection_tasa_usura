# Tasa de Usura · Colombia

Proyección de la Tasa de Interés Bancario Corriente (TIBC) y la tasa de usura
a partir de desembolsos ponderados del sistema financiero colombiano.

🌐 **[Ver sitio web](https://tu-usuario.github.io/tasa-usura)**

---

## Estructura

```
tasa-usura/
├── R/
│   └── 04__Calculo_tasa_usura.R   # Script principal
├── Insumos/                        # Datos de entrada (no versionados)
├── Salida/                         # Resultados generados (no versionados)
├── logs/                           # Logs de incidencias
├── docs/                           # Sitio web (GitHub Pages)
├── _quarto.yml                     # Config del sitio Quarto
└── .github/workflows/deploy.yml    # CI/CD automático
```

## Requisitos

- R >= 4.2
- Paquetes: `data.table`, `arrow`, `readxl`, `openxlsx`, `httr`, `jsonlite`, `janitor`, `pacman`

## Uso

1. Colocar `BD_Agrupada.parquet` en `Insumos/`
2. Colocar `fecha_cortes.xlsx` y `factores.xlsx` en la raíz / `Salida/`
3. Abrir el proyecto en RStudio
4. Ejecutar `R/04__Calculo_tasa_usura.R`

## Fuentes

- **Desembolsos:** Base interna `BD_Agrupada.parquet`
- **TIBC real:** [datos.gov.co](https://www.datos.gov.co/resource/pare-7x5i.json) · API pública SFC

## Metodología

```
TIBC_p  = Σ(Tasa × Monto × Factor) / Σ(Monto × Factor)
Usura_p = TIBC_p × 1.5
ΔTIBC   = TIBC_p − TIBC_r
```

Ver metodología completa en el [sitio web](https://tu-usuario.github.io/tasa-usura).
