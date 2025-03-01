# Some datasets need custom processing

#' Parse a custom file from d20190830_LIANG
#'
#' @param path Data directory path, character
#' @return A \code{data.frame} containing extracted data.
#' @keywords internal
#' @details This is a complicated one: the authors posted their data on
#' Figshare (good), but provide only raw CO2 concentration data.
#' Need to read each file, compute the flux for each
#' chamber at each timestep, and stitch together. This is slow.
#' @note One of the files had a corrupted character: in
#' \code{Miyazaki_Efflux_txt_Stage_2/Efflux_2/Miyazaki201205.dat} had
#' to change a stray "(" to "," line 365560. This is noted in the
#' README in the raw data folder.
#' @importFrom stats lm
#' @importFrom utils head
#' @importFrom utils tail write.table
parse_d20190830_LIANG <- function(path) {
  files <- list.files(path, pattern = ".dat$", full.names = TRUE, recursive = TRUE)
  co2files <- grep("Environ", files, invert = TRUE)
  results <- list()

  for(f in seq_along(co2files)) {
    fn <- files[co2files][f]
    message(f, "/", length(co2files), " ", fn)
    #    cat(f, "/", length(co2files), " ", fn, "\n", file = "~/Desktop/log.txt", append = T)

    # Find and parse the header; its location varies by file
    top <- readLines(fn, n = 50)
    hl <- grep("TIMESTAMP", top)
    stopifnot(length(hl) == 1)
    hdr <- gsub('\\\"', "", top[hl])
    hdr <- strsplit(hdr, ",")[[1]]

    dat <- read.table(fn,
                      skip = hl + 1,  # skip units line after the header
                      sep = ",",
                      header = FALSE,
                      col.names = hdr,
                      na.strings = "NAN",
                      stringsAsFactors = FALSE)

    dat$TS <- as.POSIXct(dat$TIMESTAMP, format = "%Y-%m-%d %H:%M:%S")
    dat <- dat[!is.na(dat$CO2) & !is.na(dat$TS),]
    dat <- dat[dat$Chamber > 0,]

    # Find new-chamber rows
    newchamber <- which(head(dat$Chamber, -1) != tail(dat$Chamber, -1)) + 1
    newchamber <- c(1, newchamber, nrow(dat) + 1)

    # This is an expensive step; create one d.f. per file
    resultsdf <- tibble(TIMESTAMP = rep(NA_character_, length(newchamber) - 1),
                        RECORD = NA_integer_,
                        Chamber = NA_integer_,
                        CO2 = NA_real_,
                        Tsoil = NA_real_,
                        Tair = NA_real_,
                        N = NA_integer_,
                        R2 = NA_real_,
                        Humity = NA_real_,
                        Flux = NA_real_,
                        Error = FALSE)

    for(i in seq_along(tail(newchamber, -1))) {
      d <- dat[newchamber[i]:(newchamber[i+1] - 1),]

      # Metadata says to use Equation 2 from https://www.nature.com/articles/sdata201726
      # Rs = 60.14 * Pair / (Tair + 273.15) * deltaC / deltaT
      d$secs <- d$TS - d$TS[1]
      m <- try(lm(CO2 ~ secs, data = d), silent = TRUE)
      mean_tair <- mean(d$Tair)
      if(class(m) == "lm") {
        resultsdf$Flux[i] <- 60.14 * 99.79 / (mean_tair + 273.15) * m$coefficients["secs"]
        resultsdf$R2[i] <- summary(m)$r.squared
      } else {
        resultsdf$Error[i] <- TRUE
      }

      if("Humity" %in% names(d)) {
        resultsdf$Humity[i] <- mean(d$Humity)
      }
      if("RECORD" %in% names(d)) {
        resultsdf$RECORD[i] <- d$RECORD[1]
      }

      resultsdf$TIMESTAMP[i] <- d$TIMESTAMP[1]
      resultsdf$Chamber[i] <- d$Chamber[1]
      resultsdf$CO2[i] <- mean(d$CO2)
      resultsdf$Tsoil[i] <- mean(d$Tsoil)
      resultsdf$Tair[i] <- mean_tair
      resultsdf$N[i] <- nrow(d)
    }
    results[[f]] <- resultsdf
  }
  rbind_list(results)
}

#' Parse one of the d20190617_SCOTT custom files
#'
#' @param path Data directory path, character
#' @param skip Lines to skip, integer
#' @param path Ports, an integer vector
#' @return A \code{data.frame} containing extracted data.
#' @importFrom utils read.csv
#' @keywords internal
parse_d20190617_SCOTT_xxx <- function(path, skip, ports) {
  files <- list.files(path, pattern = ".csv$", full.names = TRUE, recursive = TRUE)
  # File has header lines need to skip, and is in wide format
  # Build the column names
  cnames <- c("Year", "DOY")
  for(p in ports) {
    cnames <- c(cnames, paste(c("SR", "SM", "T5"), p, sep = "_"))
  }
  dat <- do.call("rbind",
                 lapply(files, read.table,
                        sep = ",",
                        header = FALSE,
                        col.names = cnames,
                        skip = skip,
                        na.strings = c("NaN"),
                        stringsAsFactors = FALSE))

  # Change the DOY column from fractional day of year to a "DOY time" string
  dat$DOY <- fractional_doy(dat$Year, dat$DOY)

  # Convert from wide to long format
  out <- data.frame()
  d <- dat[c("Year", "DOY")]
  for(p in ports) {
    dp <- d
    dp$CSR_PORT <- p
    dp$CSR_FLUX_CO2 <- dat[,paste0("SR_", p)]
    dp$CSR_SM5 <- dat[,paste0("SM_", p)]
    dp$CSR_T5 <- dat[,paste0("T5_", p)]
    out <- rbind(out, dp)
  }

  out$CSR_ERROR <- FALSE
  out
}

#' Parse a custom file from d20190617_SCOTT_SRM
#'
#' @param path Data directory path, character
#' @return A \code{data.frame} containing extracted data.
#' @keywords internal
parse_d20190617_SCOTT_SRM <- function(path) {
  parse_d20190617_SCOTT_xxx(path, skip = 10, ports = 1:3)
}

#' Parse a custom file from d20190617_SCOTT_WKG
#'
#' @param path Data directory path, character
#' @return A \code{data.frame} containing extracted data.
#' @keywords internal
parse_d20190617_SCOTT_WKG <- function(path) {
  parse_d20190617_SCOTT_xxx(path, skip = 10, ports = 1:7)
}

#' Parse a custom file from d20190617_SCOTT_WHS
#'
#' @param path Data directory path, character
#' @return A \code{data.frame} containing extracted data.
#' @keywords internal
parse_d20190617_SCOTT_WHS <- function(path) {
  parse_d20190617_SCOTT_xxx(path, skip = 10, ports = 1:8)
}

#' Parse a custom file from d20190527_GOULDEN
#'
#' @param path Data directory path, character
#' @return A \code{data.frame} containing extracted data.
#' @importFrom utils read.csv
#' @keywords internal
parse_d20190527_GOULDEN <- function(path) {
  files <- list.files(path, pattern = ".csv$", full.names = TRUE, recursive = TRUE)
  # File has header lines, and records time as fractional days since noon on 2001-01-01
  dat <- do.call("rbind", lapply(files, read.csv,
                                 skip = 14,
                                 na.strings = c("NA", "-999"),
                                 stringsAsFactors = FALSE,
                                 check.names = FALSE))
  dat$Timestamp <- as.POSIXct("2001-01-01 12:00", format = "%Y-%m-%d %H:%M")  + dat$Day_of_study * 24 * 60 * 60
  dat$Timestamp <- as.character(dat$Timestamp)
  dat$CSR_ERROR <- FALSE
  dat[dat$Vegetation == "forest",]
}


#' Parse a custom file from d20190504_SAVAGE_hf006-05
#'
#' @param path Data directory path, character
#' @return A \code{data.frame} containing extracted data.
#' @importFrom utils read.csv
#' @keywords internal
`parse_d20190504_SAVAGE_hf006-05` <- function(path) {
  dat <- parse_PROCESSED_CSV(path)

  dat_control <- dat[dat$treatment == "C",]
  dat_control$CSR_T10 <- dat_control$soilt.c
  dat_control$CSR_SM10 <- dat_control$vsm.c
  dat_trench <- dat[dat$treatment != "C",]
  dat_trench$CSR_T10 <- dat_trench$soilt.t
  dat_trench$CSR_SM10 <- dat_trench$vsm.t

  rbind_list(list(dat_control, dat_trench))
}


#' Parse a custom file from d20190504_SAVAGE_hf006-03.
#'
#' @param path Data directory path, character
#' @return A \code{data.frame} containing extracted data.
#' @importFrom utils read.csv
#' @keywords internal
`parse_d20190504_SAVAGE_hf006-03` <- function(path) {
  dat <- parse_PROCESSED_CSV(path)

  # Temperature and soil moisture data
  names(dat) <- gsub("^temp\\.ll", "CSR_T0", names(dat))
  names(dat) <- gsub("^temp", "CSR_T", names(dat))
  names(dat) <- gsub("^mois", "CSR_SM", names(dat))

  # Flux fields
  fluxcols <- grep("^flux", names(dat))
  minigather(dat, names(dat)[fluxcols], "CSR_PORT", "flux",
             new_categories = seq_along(fluxcols))
}


#' Parse a custom eofFD (forced diffusion) file from d20190430_DESAI
#'
#' @param path Data directory path, character
#' @return A \code{data.frame} containing extracted data.
#' @importFrom utils read.csv
#' @keywords internal
parse_d20190430_DESAI <- function(path) {
  dat <- parse_PROCESSED_CSV(path)
  dat <- as.data.frame(dat)

  results <- list()
  for(p in 1:4) {   # four separate ports in the file
    p_chr <- paste0("P", p)
    x <- dat[c("Time.UTC")]
    x$CSR_FLUX_CO2 <- dat[,paste0("QCCombo.Flux.", p_chr)]
    x$CSR_PORT <- p

    # Extract port-specific temperature at various depths...
    temps <- grep(paste0("^Ts.*", p_chr), names(dat))
    x <- cbind(x, dat[temps])
    names(x) <- gsub(paste0("Ts\\.", p_chr, "\\."), "CSR_T", names(x))

    # ...and moisture
    sm <- grep(paste0("^VWC.*", p_chr), names(dat))
    x <- cbind(x, dat[sm])
    names(x) <- gsub(paste0("VWC\\.", p_chr, "\\."), "CSR_SM", names(x))

    results[[p_chr]] <- x
  }

  rbind_list(results)
}

#' Parse a custom file from d20200109_HIRANO_PDB.
#'
#' @param path Data directory path, character
#' @return A \code{data.frame} containing extracted data.
#' @keywords internal
`parse_d20200109_HIRANO_PDB` <- function(path) {
  dat <- parse_PROCESSED_CSV(path)

  dat <- subset(dat, !(dat$DOY == 366 & dat$Time == 2400)) # drops one oddball row with no flux
  dat$DOYfrac <- fractional_doy(dat$Year, dat$DOY + dat$Time / 2400)

  # Flux fields
  fluxcols <- grep("^SR", names(dat))
  minigather(dat, names(dat)[fluxcols], "port", "flux", new_categories = seq_along(fluxcols))
}

#' Parse a custom file from d20200109_HIRANO_PDF.
#'
#' @param path Data directory path, character
#' @return A \code{data.frame} containing extracted data.
#' @keywords internal
`parse_d20200109_HIRANO_PDF` <- function(path) {
  parse_d20200109_HIRANO_PDB(path)
}

#' Parse a custom file from d20200109_HIRANO_PUF.
#'
#' @param path Data directory path, character
#' @return A \code{data.frame} containing extracted data.
#' @keywords internal
`parse_d20200109_HIRANO_PUF` <- function(path) {
  parse_d20200109_HIRANO_PDB(path)
}


#' Parse a custom file from d20200122_BLACK
#'
#' @param path Data directory path, character
#' @return A \code{data.frame} containing extracted data.
#' @keywords internal
`parse_d20200122_BLACK` <- function(path) {
  dat <- parse_PROCESSED(path)

  dat$Timestamp <- as.character(dat$days_since_20040101 * 24 * 60 * 60 +
                                  strptime("20040101", format("%Y%m%d")))

  # Flux fields
  fluxcols <- grep("^flux_", names(dat))
  minigather(dat, names(dat)[fluxcols], "port", "flux",
             new_categories = c(2, 3, 4, 5, 6, 9, 10, 11, 12) # custom sequence
  )
}


#' Parse a custom file from d20200108_JASSAL
#'
#' @param path Data directory path, character
#' @return A \code{data.frame} containing extracted data.
#' @keywords internal
parse_d20200108_JASSAL <- function(path) {
  dat <- parse_PROCESSED(path)

  dat$Timestamp <- as.character(dat$Days_since_20060100 * 24 * 60 * 60 +
                                  strptime("20060101", format("%Y%m%d")))

  # Flux fields
  fluxcols <- grep("^flux_", names(dat))
  minigather(dat, names(dat)[fluxcols], "port", "flux", new_categories = 1:6)
}


#' Parse a custom file from d20200212_ATAKA.
#'
#' @param path Data directory path, character
#' @return A \code{data.frame} containing extracted data.
#' @keywords internal
parse_d20200212_ATAKA <- function(path) {
  dat <- parse_PROCESSED(path)

  # Flux fields
  fluxcols <- grep("^RS[12]$", names(dat))
  minigather(dat, names(dat)[fluxcols], "port", "flux",
             new_categories = c(1, 2) # custom sequence
  )
}

#' Parse a custom file from d20200214_SZUTU_BOULDINC.
#'
#' @param path Data directory path, character
#' @return A \code{data.frame} containing extracted data.
#' @keywords internal
parse_d20200214_SZUTU_BOULDINC <- function(path) {
  files <- list.files(path, pattern = ".csv$", full.names = TRUE, recursive = TRUE)
  dat <- rbind_list(lapply(files, read.csv,
                           na.strings = c("NA", "-9999", "#VALUE!", "#REF!"),
                           stringsAsFactors = FALSE,
                           check.names = TRUE))

  cn <- c("datetime", "flux", "t5")
  x <- dat[c(1:3)]
  colnames(x) <- cn
  x$port <- 1
  y <- dat[c(4:6)]
  colnames(y) <- cn
  y$port <- 2
  z <- dat[c(7:9)]
  colnames(z) <- cn
  z$port <- 3

  rbind(x, y, z)
}

#' Parse a custom file from d20200214_SZUTU_VAIRA.
#'
#' @param path Data directory path, character
#' @return A \code{data.frame} containing extracted data.
#' @keywords internal
parse_d20200214_SZUTU_VAIRA <- function(path) {
  parse_d20200214_SZUTU_BOULDINC(path)
}

#' Parse a custom file from d20200214_SZUTU_TONZI.
#'
#' @param path Data directory path, character
#' @return A \code{data.frame} containing extracted data.
#' @keywords internal
parse_d20200214_SZUTU_TONZI <- function(path) {

  # These files have different headers. Who does that?!?
  files <- list.files(path, pattern = ".csv$", full.names = TRUE, recursive = TRUE)
  cn <- c("datetime", "flux", "t5")
  results <- list()
  for(f in files) {
    dat <- read.csv(f, na.strings = c("NA", "-9999", "#VALUE!", "#REF!"),
                    stringsAsFactors = FALSE,
                    check.names = FALSE)
    x <- dat[c(1:3)]
    colnames(x) <- cn
    x$port <- 1
    y <- dat[c(4:6)]
    colnames(y) <- cn
    y$port <- 2
    results[[f]] <- rbind(x, y)
    results[[f]]$CSR_ERROR <- FALSE
  }

  rbind_list(results)
}

#' Parse a custom file from d20200228_RENCHON
#'
#' @param path Data directory path, character
#' @return A \code{data.frame} containing extracted data.
#' @keywords internal
parse_d20200228_RENCHON <- function(path) {
  dat <- parse_PROCESSED_CSV(path)

  common_dat <- dat[c("DateTime", "Ta")]
  results <- list()
  ports <- c(2, 3, 6)
  for(p in ports) {
    x <- dat[c(paste0("Rsoil_R", p),
               paste0("Rsoil_R", p, "_qc"),
               paste0("Ts_R", p),
               paste0("SWC_R", p))]
    names(x) <- c("Rsoil", "Rsoil_gapfill", "Ts", "SWC")
    x$port <- p
    x <- cbind(common_dat, x)
    results[[p]] <- x[x$Rsoil_gapfill == 1,]  # remove any gapfilled data
  }
  rbind_list(results)
}

#' Parse a custom file from d20200229_PHILLIPS
#'
#' @param path Data directory path, character
#' @return A \code{data.frame} containing extracted data.
#' @importFrom lubridate mdy_hm round_date
#' @keywords internal
parse_d20200229_PHILLIPS <- function(path) {
  dat <- read.csv(file.path(path, "Claire Phillips - Rs_May2009_to_Aug2011.csv"),
                  stringsAsFactors = FALSE)
  # Flux fields
  fluxcols <- grep("^TR", names(dat))
  dat <- minigather(dat, names(dat)[fluxcols], "port", "flux",
                    new_categories = c(2, 3, 4, 5, 6, 7, 9, 10, 11, 12, 13, 14) # custom sequence
  )

  x <- read.csv(file.path(path, "Claire Phillips - SoilTemp_May2009_to_July2010.csv"),
                stringsAsFactors = FALSE)
  dat_t5 <- x[c("Time")]
  dat_t5$TR02.tcm <- rowMeans(x[c("TR02.T5cm.1", "TR02.T5cm.2")], na.rm = TRUE)
  dat_t5$TR03.tcm <- rowMeans(x[c("TR03.T5cm.1", "TR03.T5cm.2")], na.rm = TRUE)
  dat_t5$TR04.tcm <- rowMeans(x[c("TR04.T5cm.1", "TR04.T5cm.2")], na.rm = TRUE)
  dat_t5$TR05.tcm <- rowMeans(x[c("TR05.T5cm.1", "TR05.T5cm.2")], na.rm = TRUE)
  dat_t5$TR06.tcm <- rowMeans(x[c("TR06.T5cm.1", "TR06.T5cm.2")], na.rm = TRUE)
  dat_t5$TR07.tcm <- rowMeans(x[c("TR07.T5cm.1", "TR07.T5cm.2")], na.rm = TRUE)
  dat_t5$TR09.tcm <- rowMeans(x[c("TR09.T5cm.1", "TR09.T5cm.2")], na.rm = TRUE)
  dat_t5$TR10.tcm <- rowMeans(x[c("TR10.T5cm.1", "TR10.T5cm.2")], na.rm = TRUE)
  dat_t5$TR11.tcm <- rowMeans(x[c("TR11.T5cm.1", "TR11.T5cm.2")], na.rm = TRUE)
  dat_t5$TR12.tcm <- rowMeans(x[c("TR12.T5cm.1", "TR12.T5cm.2")], na.rm = TRUE)
  # 2020-03-03: removed TR13, probe 2 per Claire Phillips request - it's bad
  dat_t5$TR13.tcm <- rowMeans(x[c("TR13.T5cm.1")], na.rm = TRUE)
  dat_t5$TR14.tcm <- rowMeans(x[c("TR14.T5cm.1", "TR14.T5cm.2")], na.rm = TRUE)
  dat_t5$mergetime <- mdy_hm(dat_t5$Time)
  tempcols <- grep("^TR", names(dat_t5))
  dat_t5 <- minigather(dat_t5, names(dat_t5)[tempcols], "port", "t5",
                       new_categories = c(2, 3, 4, 5, 6, 7, 9, 10, 11, 12, 13, 14))

  # Temperature data are rounded to nearest :30
  # Merge flux data with averaged temperature data
  dat$mergetime <- round_date(mdy_hm(dat$Period.Start), "30 minutes")
  dat <- merge(dat, dat_t5)
  dat$mergetime <- dat$Time <- NULL
  dat
}

# Test code to ensure correct dispatching for custom file format.
parse_TEST_custom <- function(path) {
  stop("TEST_custom dispatched OK")
}

#' Parse a custom file from d20190919_MIGLIAVACCA
#'
#' @param path Data directory path, character
#' @return A \code{data.frame} containing extracted data.
#' @keywords internal
parse_d20190919_MIGLIAVACCA <- function(path) {
  parse_PROCESSED_CSV(path, extension_pattern = "dat$")
}

#' Parse a custom file from d20200305_VARGAS
#'
#' @param path Data directory path, character
#' @return A \code{data.frame} containing extracted data.
#' @keywords internal
#' @importFrom tibble tibble
parse_d20200305_VARGAS <- function(path) {
  dat <- parse_PROCESSED_CSV(path)

  # Argh who does this to their dates?!?
  y2007 <- dat$Year == 2007
  dat$DOY[y2007] <- dat$DOY[y2007] - 365
  y2008 <- dat$Year == 2008
  dat$DOY[y2008] <- dat$DOY[y2008] - 729

  dat1 <- tibble(
    Year = dat$Year,
    DOY = dat$DOY,
    port = 1,
    flux = dat$EffluxL_avg,
    PAR = dat$PAR,
    RH = dat$RHL_avg,
    SM10 = dat$SVWCL,
    Ta = dat$TaL_avg,
    Ts_16 = dat$Ts_16L_avg,
    Ts_2 = dat$Ts_2L_avg,
    Ts_8 = dat$Ts_8L_avg,
    label = "Lower plot"
  )
  dat2 <- tibble(
    Year = dat$Year,
    DOY = dat$DOY,
    port = 2,
    flux = dat$EffluxM_avg,
    PAR = dat$PAR,
    RH = dat$RHM_avg,
    SM10 = dat$SVWCM,
    Ta = dat$TaM_avg,
    Ts_16 = dat$Ts_16M_avg,
    Ts_2 = dat$Ts_2M_avg,
    Ts_8 = dat$Ts_8M_avg,
    label = "Middle plot"
  )
  dat3 <- tibble(
    Year = dat$Year,
    DOY = dat$DOY,
    port = 3,
    flux = dat$EffluxU_avg,
    PAR = dat$PAR,
    RH = dat$RHU_avg,
    SM10 = dat$SVWCU,
    Ta = dat$TaU_avg,
    Ts_16 = dat$Ts_16U_avg,
    Ts_2 = dat$Ts_2U_avg,
    Ts_8 = dat$Ts_8U_avg,
    label = "Upper plot"
  )
  rbind(dat1, dat2, dat3)
}

#' Parse a custom file from d20200328_UEYAMA_FAIRBANKS
#'
#' @param path Data directory path, character
#' @return A \code{data.frame} containing extracted data.
#' @keywords internal
#' @importFrom tibble tibble
parse_d20200328_UEYAMA_FAIRBANKS <- function(path) {
  files <- list.files(path, pattern = ".csv$", full.names = TRUE, recursive = TRUE)
  dat <- read.csv(files, na.strings = c("#N/A", "#DIV/0!"),
                  stringsAsFactors = FALSE, check.names = FALSE, skip = 1)

  dat1 <- dat
  dat1$Fch4 <- dat$Fch4_1
  dat1$Fco2 <- dat$Fco2_1
  dat1$T5 <- dat$Tsoil1
  dat1$VWC <- dat$VWC1
  dat1$Port <- 1

  dat3 <- dat
  dat3$Fch4 <- dat$Fch4_3
  dat3$Fco2 <- dat$Fco2_3
  dat3$T5 <- dat$Tsoil3
  dat3$VWC <- dat$VWC3
  dat3$Port <- 3

  dat4 <- dat
  dat4$Fch4 <- dat$Fch4_4
  dat4$Fco2 <- dat$Fco2_4
  dat4$T5 <- dat$Tsoil1  # per author
  dat4$VWC <- dat$VWC1
  dat4$Port <- 4

  dat <- rbind(dat1, dat3, dat4)
  dat$Fch4_1 <- dat1$Fco2_1 <-
    dat1$Fch4_3 <- dat1$Fco2_3 <-
    dat1$Fch4_4 <- dat1$Fco2_4 <-
    dat$Tsoil1 <- dat$Tsoil2 <- dat$Tsoil3 <-
    dat$VWC1 <- dat$VWC2 <- NULL

  dat$O2 <- rowMeans(dat[c("O2_1", "O2_2")], na.rm = TRUE)
  dat$VWC <- dat$VWC / 100

  dat
}

#' Parse a custom file from d20200328_UEYAMA_HOKUROKU
#'
#' @param path Data directory path, character
#' @return A \code{data.frame} containing extracted data.
#' @keywords internal
#' @importFrom tibble tibble
parse_d20200328_UEYAMA_HOKUROKU <- function(path) {
  files <- list.files(path, pattern = ".csv$", full.names = TRUE, recursive = TRUE)
  dat <- rbind_list(lapply(files, read.csv,
                           na.strings = c("#N/A", "#DIV/0!"),
                           stringsAsFactors = FALSE,
                           check.names = FALSE, skip = 1))

  fields <- c("Fch4", "Fco2", "Ts", "SWC")
  dats <- list()
  for(i in 1:6) {
    dats[[i]] <- dat[c("StartTime", paste(fields, i, sep = "_"))]
    names(dats[[i]]) <- c("StartTime", fields)
    dats[[i]]$Port <- i
  }

  rbind_list(dats)
}

#' Parse a custom file from d20200328_UEYAMA_TESHIO
#'
#' @param path Data directory path, character
#' @return A \code{data.frame} containing extracted data.
#' @keywords internal
#' @importFrom tibble tibble
parse_d20200328_UEYAMA_TESHIO <- function(path) {
  files <- list.files(path, pattern = ".csv$", full.names = TRUE, recursive = TRUE)
  dat <- read.csv(files, na.strings = c("#N/A", "#DIV/0!"),
                  stringsAsFactors = FALSE, check.names = FALSE, skip = 1)

  dat_all <- dat[c("TIMESTAMP", "Ts1", "Twater", "WaterTable")]
  dat1 <- dat2 <- dat3 <- dat4 <- dat_all

  dat1$Fch4 <- dat$Fch4_1
  dat1$Fco2 <- dat$Fco2_1
  dat1$SWC <- dat$SWC1
  dat1$Port <- 1
  dat2$Fch4 <- dat$Fch4_2
  dat2$Fco2 <- dat$Fco2_2
  dat2$SWC <- dat$SWC1
  dat2$Port <- 2
  dat3$Fch4 <- dat$Fch4_3
  dat3$Fco2 <- dat$Fco2_3
  dat3$SWC <- dat$SWC3
  dat3$Port <- 3
  dat4$Fch4 <- dat$Fch4_w
  dat4$Fco2 <- dat$Fco2_w
  dat4$SWC <- NA_real_
  dat4$Port <- 4

  rbind(dat1, dat2, dat3, dat4)
}

#' Parse a custom file from d20200328_UEYAMA_YAMASHIRO
#'
#' @param path Data directory path, character
#' @return A \code{data.frame} containing extracted data.
#' @keywords internal
#' @importFrom tibble tibble
parse_d20200328_UEYAMA_YAMASHIRO <- function(path) {
  files <- list.files(path, pattern = ".csv$", full.names = TRUE, recursive = TRUE)
  dat <- rbind_list(lapply(files, read.csv,
                           na.strings = c("#N/A", "#DIV/0!"),
                           stringsAsFactors = FALSE,
                           check.names = FALSE, skip = 1))

  dat1 <- dat2 <- dat3 <- dat4 <- dat[c("TIMESTAMP")]

  # per Ueyama email 2020-04-02 SWC headers in file not correct, which is
  # why assignments below
  dat1$Fch4 <- dat$Fch4_1
  dat1$Fco2 <- dat$Fco2_1
  dat1$SWC <- dat$`SWC.1_0-5cm`
  dat1$Tsoil <- dat$Tsoil.1_3cm
  dat1$Port <- 1
  dat2$Fch4 <- dat$Fch4_2
  dat2$Fco2 <- dat$Fco2_2
  dat2$SWC <- dat$`SWC.2_0-5cm`
  dat2$Tsoil <- dat$Tsoil.2_3cm
  dat2$Port <- 2
  dat3$Fch4 <- dat$Fch4_3
  dat3$Fco2 <- dat$Fco2_3
  dat3$SWC <- dat$`SWC.3_0-5cm`
  dat3$Tsoil <- dat$Tsoil.3_3cm
  dat3$Port <- 3
  dat4$Fch4 <- dat$Fch4_4
  dat4$Fco2 <- dat$Fco2_4
  dat4$SWC <- dat$`SWC.4_0-5cm`
  dat4$Tsoil <- NA_real_
  dat4$Port <- 4

  rbind(dat1, dat2, dat3, dat4)
}

#' Parse a custom file from parse_d20200407_WANG
#'
#' @param path Data directory path, character
#' @return A \code{data.frame} containing extracted data.
#' @keywords internal
#' @importFrom lubridate round_date
parse_d20200407_WANG <- function(path) {
  files <- list.files(path, pattern = "Chamber.*csv$", full.names = TRUE, recursive = TRUE)
  dat <- rbind_list(lapply(files, read.csv,
                           na.strings = c("#N/A", "#DIV/0!"),
                           stringsAsFactors = FALSE,
                           check.names = FALSE))
  # The T and SM data, helpfully provided in separate files and with different timestamp formats,
  # are on the half-hour. Round the flux timestamps for merging
  dat$ts <- strptime(paste(dat$Rtu_Date, dat$Rtu_Time), "%m/%d/%Y %H:%M:%S", tz = "UTC")
  dat$ts_rnd <- as.character(round_date(dat$ts, "30 minutes"))

  files <- list.files(path, pattern = "moisture.*csv$", full.names = TRUE, recursive = TRUE)
  sm10 <- rbind_list(lapply(files, read.csv,
                            na.strings = c("#N/A", "#DIV/0!"),
                            stringsAsFactors = FALSE,
                            check.names = FALSE))
  sm10 <- minigather(sm10, c("Chamber 1", "Chamber 2", "Chamber 3"), "chamber", "sm10", new_categories = 1:3)
  sm10$ts_rnd <- as.character(strptime(sm10$Time, "%Y/%m/%d %H:%M"))

  files <- list.files(path, pattern = "temperature.*csv$", full.names = TRUE, recursive = TRUE)
  t10 <- rbind_list(lapply(files, read.csv,
                           na.strings = c("#N/A", "#DIV/0!"),
                           stringsAsFactors = FALSE,
                           check.names = FALSE))
  t10 <- minigather(t10, c("Chamber1", "Chamber2", "Chamber 3"), "chamber", "t10", new_categories = 1:3)
  t10$ts_rnd <- as.character(strptime(t10$Time, "%Y/%m/%d %H:%M"))

  # merge chokes on merging by timestamp, so we've converted those to character
  dat <- merge(merge(dat, sm10, all.x = TRUE), t10, all.x = TRUE)
  dat[c("Chamber_name", "Rtu_Date", "Rtu_Time", "CH4_Flux_nmol/m2*s", "sm10", "t10")]
}

#' Parse a custom file from d20200419_PEREZ_QUEZADA
#'
#' @param path Data directory path, character
#' @return A \code{data.frame} containing extracted data.
#' @keywords internal
`parse_d20200419_PEREZ-QUEZADA` <- function(path) {
  dat <- parse_PROCESSED_CSV(path)

  dats <- list()
  for(i in 1:5) {
    dats[[i]] <- dat[c("Date", "Hour", paste0("FLUX_", i), paste0("TEMP_", i))]
    names(dats[[i]]) <- c("Date", "Hour", "FLUX", "TEMP")
    dats[[i]]$port <- i
  }

  rbind_list(dats)
}

#' Parse a custom file from d20200423_SANCHEZ-CANETE
#'
#' @param path Data directory path, character
#' @return A \code{data.frame} containing extracted data.
#' @keywords internal
`parse_d20200423_SANCHEZ-CANETE` <- function(path) {
  dat <- parse_PROCESSED_CSV(path)

  dats <- list()
  for(i in 1:3) {
    dats[[i]] <- dat[c("TIMESTAMP", paste0("Fc_", i), paste0("SWC_", i), paste0("Temp_", i))]
    names(dats[[i]]) <- c("TIMESTAMP", "Fc", "SWC", "Temp")
    dats[[i]]$port <- i
  }

  rbind_list(dats)
}

#' Parse a custom file from d20200423_OYONARTE
#'
#' @param path Data directory path, character
#' @return A \code{data.frame} containing extracted data.
#' @keywords internal
parse_d20200423_OYONARTE <- function(path) {
  dat <- parse_PROCESSED_CSV(path)

  dats <- list()
  p <- 1
  for(i in c("UP", "BS")) {
    dats[[i]] <- dat[c(paste0("SF_", i), paste0("SWC_", i), paste0("Temp_", i))]
    names(dats[[i]]) <- c("SF", "SWC", "Temp")
    dats[[i]]$Timestamp <- with(dat, paste(Year, Month, Day, Hour, Minute))
    dats[[i]]$port <- p
    p <- p + 1
  }

  rbind_list(dats)
}

#' Parse a custom file from d20200825_MINIAT
#'
#' @param path Data directory path, character
#' @return A \code{data.frame} containing extracted data.
#' @keywords internal
parse_d20200825_MINIAT <- function(path) {
  dat <- parse_PROCESSED_CSV(path)

  # This is complex
  # There is site (hardwood, ball creek, shope fork); plot; treatment; and surface
  # All this gets wrapped up into our port and treatments fields
  port <- gsub("\\D", "", dat$Plot) # e.g. 1.1-4 -> 114
  dat$Surface <- trimws(dat$Surface)

  # We compute all this to put into the PORT file
  treatments <- rep("None", nrow(dat))
  treatments[dat$tmt == "hdwd" & dat$Surface == "c"] <- "Partial O horizon"
  treatments[dat$tmt == "hdwd" & dat$Surface == "u"] <- "None"
  treatments[dat$tmt == "gird" & dat$Surface == "c"] <- "Girdled, partial O horizon"
  treatments[dat$tmt == "gird" & dat$Surface == "u"] <- "Girdled"
  treatments[dat$tmt == "hem" & dat$Surface == "c"] <- "Woody adelgid, partial O horizon"
  treatments[dat$tmt == "hem" & dat$Surface == "u"] <- "Woody adelgid"

  species <- rep("Tsuga canadensis", nrow(dat)) # hemlock and girdled
  species[dat$tmt == "hdwd"] <- "Liriodendron tulipifera, Acer rubrum, Quercus spp., Carya spp., Rhododendron maximum"

  covers <- as.integer(as.factor(dat$Surface))
  ports <- paste0(port, covers) # now 1141 or 1142 e.g.
  dat$port <- ports

  miniat_ports <- tibble(port = ports,
                         rs = "Rs",
                         treatments = treatments,
                         fan = "TRUE",
                         area = 71.6,
                         vol = 991,
                         depth = 0.5,
                         species = species)
  miniat_ports
  #  write.csv(miniat_ports, "~/Desktop/miniat_ports.csv", row.names = FALSE)
  dat
}
