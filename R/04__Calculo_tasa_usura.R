# =============================================================================
# Cálculo Tasa de Usura
# =============================================================================

# 1. Setup --------------------------------------------------------------------

  # Limpieza de memoria antes de cualquier carga
  rm(list = ls())
  invisible(gc())

  # Opciones del sistema — sin suprimir warnings globalmente
  options(
    scipen   = 999,
    digits   = 22,
    OutDec   = ",",
    max.print = 100
  )

  # Configuración de región
  suppressWarnings(invisible(Sys.setlocale("LC_ALL",  "es_ES.UTF-8")))
  suppressWarnings(invisible(Sys.setlocale("LC_TIME", "C")))
  Sys.setenv(LANG = "es.UTF-8")

  # Instalación y carga de librerías
  if (!requireNamespace("pacman", quietly = TRUE)) install.packages("pacman")
  pacman::p_load(
    data.table, arrow, readxl, openxlsx,
    janitor, httr, jsonlite,
    install = FALSE
  )

  # Ruta de trabajo relativa al script (solo en entorno interactivo)
  if (interactive()) {
    setwd(dirname(rstudioapi::getActiveDocumentContext()$path))
  }

# 2. Constantes ---------------------------------------------------------------

  COLS_BD <- c(
    "fecha_corte", "nombre_entidad", "producto_de_credito",
    "plazo_de_credito", "rango_monto_desembolsado", "tipo_de_tasa",
    "tasa_efectiva_promedio_ponderada", "montos_desembolsados"
  )

  RUTA_BD        <- file.path("Insumos", "BD_Agrupada.parquet")
  RUTA_CORTES    <- "fecha_cortes.xlsx"
  RUTA_FACTORES  <- "Salida/factores.xlsx"
  RUTA_SALIDA    <- "Salida/salida.xlsx"
  RUTA_LOG_NAS   <- "logs/sin_factor.csv"

  # Columnas de unión para cada factor (en orden de sheets 1–5)
  COLS_JOIN_FACTORES <- c(
    "nombre_entidad",
    "producto_de_credito",
    "rango_monto_desembolsado",
    "plazo_de_credito",
    "tipo_de_tasa"
  )

  url_base  <- "https://www.datos.gov.co/resource/pare-7x5i.json"
  sql_query <- paste0(
    "SELECT `vigencia_desde`, `interes_bancario_corriente` ",
    "WHERE caseless_eq(`modalidad`, 'CONSUMO Y ORDINARIO') ",
    "AND `vigencia_desde` >= '2024-10-01T00:00:00'"
  )
  URL_TIBC <- paste0(url_base, "?$query=", URLencode(sql_query, repeated = TRUE))

# 3. Carga de desembolsos -----------------------------------------------------

  message(Sys.time(), " | Leyendo base de desembolsos...")

  bd <- read_parquet(RUTA_BD, col_select = COLS_BD) |> setDT()

  fecha_cortes <- read_excel(RUTA_CORTES) |>
    setDT() |>
    clean_names()

  fecha_cortes[, `:=`(
    fecha = as.IDate(fecha),
    corte = as.IDate(corte)
  )]

  bd <- bd[fecha_cortes, on = .(fecha_corte = fecha), nomatch = NULL]

  message(Sys.time(), " | Desembolsos cargados: ", format(nrow(bd), big.mark = "."), " filas")

# 4. Carga y aplicación de factores -------------------------------------------

  message(Sys.time(), " | Cargando factores...")

  factores <- lapply(seq_along(COLS_JOIN_FACTORES), function(i) {
    read_excel(RUTA_FACTORES, sheet = i) |> setDT()
  })

  for (i in seq_along(factores)) {
    col_join  <- COLS_JOIN_FACTORES[i]
    col_nueva <- paste0("factor_", i)
    bd[factores[[i]], on = (col_join), (col_nueva) := i.factor]
  }

  # Normalizar todos los factores a double antes de operar
  cols_factores <- paste0("factor_", 1:5)
  bd[, (cols_factores) := lapply(.SD, as.double), .SDcols = cols_factores]

  bd[, factor_a := fcoalesce(factor_1, 1) *
                   fcoalesce(factor_2, 1) *
                   fcoalesce(factor_3, 1) *
                   fcoalesce(factor_4, 1) *
                   fcoalesce(factor_5, 1)]

  # Log de combinaciones sin factor asignado
  cols_diagnostico <- c(
    "nombre_entidad", "producto_de_credito",
    "plazo_de_credito", "rango_monto_desembolsado", "tipo_de_tasa"
  )

  nas_factores <- bd[
    is.na(factor_1) | is.na(factor_2) | is.na(factor_3) |
    is.na(factor_4) | is.na(factor_5),
    .SD, .SDcols = cols_diagnostico
  ] |> unique()

  if (nrow(nas_factores) > 0) {
    message("⚠️  ", nrow(nas_factores), " combinaciones sin factor asignado — ver: ", RUTA_LOG_NAS)
    dir.create(dirname(RUTA_LOG_NAS), showWarnings = FALSE, recursive = TRUE)
    fwrite(nas_factores, RUTA_LOG_NAS)
  } else {
    message(Sys.time(), " | Todos los registros tienen factor asignado ✓")
  }

# 5. Consulta TIBC desde API --------------------------------------------------

  message(Sys.time(), " | Consultando TIBC en datos.gov.co...")

  resp <- tryCatch(
    GET(URL_TIBC, timeout(30)),
    error = function(e) stop("Error de conexión al consultar la TIBC: ", e$message)
  )

  if (http_error(resp)) {
    stop("La API respondió con HTTP ", status_code(resp))
  }

  tasa_sfc <- content(resp, as = "text", encoding = "UTF-8") |>
    fromJSON() |>
    clean_names() |>
    setDT()

  tasa_sfc[, `:=`(
    vigencia_desde             = as.IDate(substr(vigencia_desde, 1, 10)),
    interes_bancario_corriente = as.numeric(sub("%", "", interes_bancario_corriente)) / 1e2
  )]

  message(Sys.time(), " | TIBC cargada: ", nrow(tasa_sfc), " registros")

# 6. Cálculo de usura proyectada ----------------------------------------------

  message(Sys.time(), " | Calculando tasas...")

  calculos <- bd[, .(
    desembolsos   = sum(montos_desembolsados, na.rm = TRUE),
    tasa_promedio = sum(tasa_efectiva_promedio_ponderada * montos_desembolsados, na.rm = TRUE) /
                   sum(montos_desembolsados, na.rm = TRUE),
    TIBC_p        = sum(tasa_efectiva_promedio_ponderada * montos_desembolsados * factor_a, na.rm = TRUE) /
                   sum(montos_desembolsados * factor_a, na.rm = TRUE)
  ), by = .(corte)]

  calculos[, USURA_p := TIBC_p * 1.5]

# 7. Enriquecer con tasas reales (SFC) ----------------------------------------

  calculos[tasa_sfc, on = .(corte = vigencia_desde), `:=`(
    TIBC_r  = i.interes_bancario_corriente,
    USURA_r = i.interes_bancario_corriente * 1.5
  )]

  calculos[, `:=`(
    delta_TIBC  = TIBC_p - TIBC_r,
    delta_USURA = USURA_p - USURA_r
  )]

# 8. Exportar resultados ------------------------------------------------------

  message(Sys.time(), " | Exportando resultados a: ", RUTA_SALIDA)

  dir.create(dirname(RUTA_SALIDA), showWarnings = FALSE, recursive = TRUE)
  write.xlsx(calculos, RUTA_SALIDA, asTable = TRUE, overwrite = TRUE)

  message(Sys.time(), " | ✅ Proceso finalizado correctamente")
