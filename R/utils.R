# utils.R


#' fractional_doy
#'
#' Convert a day of year (DOY) given as xxx.xxx to a day of year + time of day.
#' This can vary due to leap years, so we need the year in question as well.
#'
#' @param year Year, integer
#' @param doy Day of year, numeric (xxx.xxx)
#' @return A string giving day of year and time in \code{\%j \%T} format; see \code{\link{strptime}}.
#' @keywords internal
fractional_doy <- function(year, doy) {
  stopifnot(all(doy >= 1, na.rm = TRUE))
  stopifnot(all(doy < 367, na.rm = TRUE))

  doy_floor <- floor(doy)
  start <- strptime(paste(year, doy_floor, "00:00:00"), "%Y %j %T")
  frac <- doy - doy_floor
  end <- start + frac * 24 * 60 * 60
  format(end, "%j %T")
}


#' Split a raw Licor (*.81x) file into pieces.
#'
#' @param filename Fully-qualified filename, character
#' @param split_lines Rough number of lines to split by, integer
#' @param out_dir Output directory, character
#' @note Licor output files can get \emph{very} big. This utility splits (on record
#' boundaries) a file into multiple sub-files.
#' @return Number of files created, invisibly.
#' @keywords internal
split_licor_file <- function(filename, split_lines = 25000, out_dir = dirname(filename)) {

  stopifnot(split_lines > 0)
  stopifnot(file.exists(filename))
  stopifnot(dir.exists(out_dir))

  # Read file into memory and find records
  filedata <- readLines(filename)
  record_starts <- grep(pattern = "^LI-8100", filedata)
  message("Reading ", filename, ": lines = ", length(filedata), " records = ", length(record_starts))
  bfn <- gsub(".81x$", "", basename(filename))  # remove extension

  this_file_start_record <- 1
  startline <- 1
  filenum <- 0
  while(this_file_start_record <= length(record_starts)) {
    filenum <- filenum + 1
    within_file <- record_starts - record_starts[this_file_start_record] < split_lines
    within_file[this_file_start_record] <- TRUE # always write at least one record
    next_file_start_record <- max(which(within_file)) + 1

    if(next_file_start_record > length(record_starts)) {
      endline <- length(filedata)
    } else {
      endline <- record_starts[next_file_start_record] - 1
    }

    new_file <- file.path(out_dir, paste0(bfn, "_", sprintf("%06d", filenum), ".81x"))
    message("Writing lines", startline, "-", endline, "to ", new_file, "\n")
    cat(filedata[startline:endline], sep = "\n", file = new_file)
    this_file_start_record <- next_file_start_record
    startline <- endline + 1
  }
  invisible(filenum)
}

#' Insert default fields into a data frame
#'
#' @param d A tibble or data.frame
#' @param extra_fields A list of fields (the names) and their default values (elements)
#' @return The (possibly modified) data frame.
#' @keywords internal
insert_defaults <- function(d, extra_fields) {
  stopifnot(is.data.frame(d))
  stopifnot(nrow(d) > 0)
  stopifnot(is.list(extra_fields))

  for(ef in names(extra_fields)) {
    if(!ef %in% names(d)) {
      d[[ef]] <- extra_fields[[ef]]
    }
  }
  d
}

#' Insert new line(s) into existing metadata files.
#'
#' @param file Filename, character
#' @param pattern Pattern to search for, a regular expression
#' @param newlines New line(s) to write, character vector
#' @param after Insert new line(s) after pattern (T) or before (F)? Logical
#' @param path Path to search; normally the metadata are in \code{inst/extdata/datasets}
#' @param write_files Write resulting files back out? Logical
#' @return Nothing; run for side effects
#' @keywords internal
insert_line <- function(file, pattern, newlines, after = TRUE, path = "./inst/extdata/datasets", write_files = TRUE) {
  files <- list.files(path, pattern = file, full.names = TRUE, recursive = TRUE)
  message("Found ", length(files), " files")

  for(f in files) {
    dat <- readLines(f)
    pat <- grep(pattern, dat)
    ip <- pat + after  # insertion point

    if(length(ip) > 1) {
      stop("Found more than one possible insertion point in ", f)
    }
    if(length(ip)) {
      # Have we already been here?
      if(!after &&
         length(dat[ip-1]) &&  # this occurs if inserting at very beginning
         dat[ip-1] == newlines[1]) {
        warning("Lines to insert already found at line ", ip-1, " in ", f)
      } else if(after &&
                !is.na(dat[ip]) &&  # this occurs if inserting at very end
                dat[ip] == newlines[1]) {
        warning("Lines to insert already found at line ", ip, " in ", f)
      } else {
        message("Found insert point at line ", ip, " in ", f)
        newdat <- c(dat[seq_len(ip - 1)], newlines)
        if(ip <= length(dat)) {
          newdat <- c(newdat, dat[ip:length(dat)])
        }
        if(write_files) {
          message("...writing")
          writeLines(newdat, f)
        }
      }
    } else {
      warning("No insert point found in ", f)
    }
  }
}


#' Bind a list of data frames (with possibly non-identical column names) together.
#'
#' @param x List of data frames
#' @return A single \code{data.frame} with all data together
#' @importFrom tibble tibble as_tibble
#' @export
rbind_list <- function(x) {
  stopifnot(is.list(x))
  if(length(x) == 0) return(tibble())

  # Everything in x has to be data.frame-equivalent or NULL
  stopifnot(all(vapply(x, function(x) {
    any(c("data.frame", "NULL") %in% class(x))
  }
  , FUN.VALUE = logical(1))))

  all_names <- unique(unlist(lapply(x, function(x) names(x))))

  as_tibble(
    do.call(rbind,
            c(lapply(x, function(x_entry) {
              if(is.null(x_entry)) {
                data.frame()
              } else {
                data.frame(c(x_entry, vapply(setdiff(all_names, names(x_entry)),
                                             function(y) NA,
                                             FUN.VALUE = logical(1))),
                           check.names = FALSE, stringsAsFactors = FALSE)
              }
            }), make.row.names = FALSE, stringsAsFactors = FALSE))
  )
}


#' Write out standardized data and diagnostics tables
#'
#' This is typically used to write standardized data
#' to \code{inst/extdata/datasets}. These data can be removed
#' using \code{\link{csr_remove_stan_data}}.
#'
#' @param dataset A COSORE dataset, list
#' @param path Output path (typically \code{inst/extdata/datasets}), character
#' @param create_dirs Create subdirectories as needed? Logical
#' @return Nothing.
#' @export
csr_standardize_data <- function(dataset, path, create_dirs = FALSE) {

  stopifnot(is.list(dataset))
  stopifnot(is.character(path))
  stopifnot(is.logical(create_dirs))

  dataset_name <- dataset$description$CSR_DATASET
  message("Writing data and diagnostic tables for ", dataset_name, "...")

  outpath <- file.path(path, dataset_name, "data")
  if(!dir.exists(outpath)) {
    if(create_dirs) {
      message("Creating ", outpath)
      dir.create(outpath, recursive = TRUE)
    } else {
      stop(outpath, " does not exist")
    }
  }

  write_stan_data(dataset, outpath)

  invisible(NULL)
}

#' Write standardized data, diagnostics, and perhaps a gitignore file
#'
#' @param dataset Dataset, a list
#' @param outpath Output path to write to, character
#' @return Nothing.
#' @keywords internal
#' @note This is called only by \code{\link{csr_standardize_data}}.
write_stan_data <- function(dataset, outpath) {
  stopifnot(is.list(dataset))
  stopifnot(is.character(outpath))

  if(is.data.frame(dataset$data)) {
    # Write respiration data
    # csv (big, version control friendly) or RDS (small, fast, preserves types)?
    # Going with the latter for now
    outfile <- file.path(outpath, "data.RDS")
    saveRDS(dataset$data, file = outfile)

    # Write diagnostics data
    diagfile <- file.path(outpath, "diag.RDS")
    saveRDS(dataset$diagnostics, file = diagfile)

    # If these data are embargoed, write a .gitignore file
    # If not, remove any existing .gitignore file
    gitignore <- file.path(outpath, ".gitignore")
    if(embargoed(dataset)) {
      message("This dataset has an embargo entry; writing .gitignore")
      cat("# This dataset is embargoed", "*.RDS", sep = "\n", file = gitignore)
    } else {
      unlink(gitignore)
    }
  }
}

#' Check whether a dataset is embargoed
#' @param ds The dataset
#' @return TRUE or FALSE.
#' @keywords internal
embargoed <- function(ds) {
  stopifnot(is.list(ds))
  "CSR_EMBARGO" %in% names(ds$description) &&
    !is.na(ds$description$CSR_EMBARGO)
}

#' Remove standardized dataset(s)
#'
#' Utility function that remove standardized datasets created
#' by \code{\link{csr_standardize_data}} from a
#' directory tree, specifically \code{{path}/dataset/data/*.RDS}.
#'
#' @param path Path, typically \code{inst/extdata/datasets/}
#' @param datasets Optional character vector of datasets. If not
#' supplied, the output of \code{\link{list_datasets}} is used.
#' @return Nothing.
#' @export
csr_remove_stan_data <- function(path, datasets = list_datasets()) {
  for(ds in datasets) {
    message(ds)
    data_dir <- file.path(path, ds, "data")
    if(!dir.exists(data_dir)) {
      message("\tNo data directory")
      next
    }
    files <- list.files(data_dir, pattern = "*.RDS", full.names = TRUE)
    message("\tRemoving ", length(files), " file(s)")
    unlink(files)
  }
}


#' Convert a vector of strings to POSIXct timestamps.
#'
#' @param ts Timestamps, character
#' @param timestamp_format Formatting string that \code{\link{as.POSIXct}} accepts.
#' This normally comes from \code{CSR_TIMESTAMP_FORMAT} in the DESCRIPTION file.
#' @param time_zone Time zone that \code{\link{as.POSIXct}} accepts.
#' This normally comes from \code{CSR_TIMESTAMP_TZ} in the DESCRIPTION file.
#' @return A list with (i) a vector of \code{POSIXct} timestamps, (ii) a logical vector
#' indicating which ones are invalid (and thus now NA), and (iii) a string of examples of
#' bad timestamps.
#' @keywords internal
convert_and_qc_timestamp <- function(ts, timestamp_format, time_zone) {
  stopifnot(is.character(ts))
  stopifnot(is.character(timestamp_format))
  stopifnot(is.character(time_zone))

  new_ts <- as.POSIXct(ts, format = timestamp_format, tz = time_zone)
  na_ts <- is.na(new_ts) & !is.na(ts)
  bad_examples <- paste(head(ts[na_ts]), collapse = ", ")
  list(new_ts = new_ts, na_ts = na_ts, bad_examples = bad_examples)
}

#' Convert ancillary timestamps to POSIXct
#'
#' @param ancillary An ancillary data frame
#' @param tz Time zone
#' @param dataset_name The dataset name
#' @return The ancillary data frame
#' @keywords internal
#' @note Called only by \code{\link{read_dataset}}.
convert_ancillary_timestamps <- function(ancillary, tz, dataset_name) {
  stopifnot(is.data.frame(ancillary))
  stopifnot(is.character(tz))

  # Convert the ancillary table timestamps to POSIXct
  if("CSR_TIMESTAMP_BEGIN" %in% names(ancillary)) { # might have been removed if no data
    x <- calc_timestamps(ancillary, 0, "%F %T", tz)

    if(any(x$na_ts & ancillary$CSR_TIMESTAMP_BEGIN != "", na.rm = TRUE)) {
      stop("Invalid timestamps in the ANCILLARY.csv file for ", dataset_name,
           " e.g. rows: ", head(which(x$na_ts)))
    }
    ancillary <- x$dsd
  }
  ancillary
}

#' Calculate all timestamps based on timestamps given and measurement length
#'
#' @param dsd Dataset data, a data frame
#' @param ml Measurement length, numeric (seconds)
#' @param tf Timestamp format, a \code{\link{strptime}} format string
#' @param tz Timezone, character
#' @keywords internal
#' @note This is called from \code{\link{read_raw_dataset}}.
#' @return A list with (i) the new dataset data.frame, (ii) a logical vector
#' indicating which ones are invalid (and thus now NA), and
#' (iii) a string of examples of bad timestamps.
calc_timestamps <- function(dsd, ml, tf, tz) {
  stopifnot(is.data.frame(dsd))
  stopifnot(is.numeric(ml))
  stopifnot(is.character(tf))
  stopifnot(is.character(tz))

  if(nrow(dsd) == 0) {
    return(list(dsd = dsd,
         new_ts = NA,
         na_ts = NA,
         bad_example = ""))
  }
  stopifnot(is.numeric(ml))
  stopifnot(is.character(tf))
  stopifnot(is.character(tz))

  ts_begin <- "CSR_TIMESTAMP_BEGIN" %in% names(dsd)
  ts_mid <- "CSR_TIMESTAMP_MID" %in% names(dsd)
  ts_end <- "CSR_TIMESTAMP_END" %in% names(dsd)

  if(ts_end & !ts_begin) {   # end present; compute begin
    x <- convert_and_qc_timestamp(dsd$CSR_TIMESTAMP_END, tf, tz)
    dsd$CSR_TIMESTAMP_END <- x$new_ts
    dsd$CSR_TIMESTAMP_BEGIN <- x$new_ts - ml
    return(c(list(dsd = dsd), x))

  } else if(ts_begin & !ts_end) {   # begin present; compute end
    x <- convert_and_qc_timestamp(dsd$CSR_TIMESTAMP_BEGIN, tf, tz)
    dsd$CSR_TIMESTAMP_BEGIN <- x$new_ts
    dsd$CSR_TIMESTAMP_END <- x$new_ts + ml
    return(c(list(dsd = dsd), x))

  } else if(ts_mid & !ts_begin & !ts_end) {
    x <- convert_and_qc_timestamp(dsd$CSR_TIMESTAMP_MID, tf, tz)
    dsd$CSR_TIMESTAMP_BEGIN <- x$new_ts - ml / 2
    dsd$CSR_TIMESTAMP_END <- x$new_ts + ml / 2
    dsd$CSR_TIMESTAMP_MID <- NULL
    return(c(list(dsd = dsd), x))

  } else if(ts_begin & ts_end) {  # both present; nothing to compute
    x_begin <- convert_and_qc_timestamp(dsd$CSR_TIMESTAMP_BEGIN, tf, tz)
    dsd$CSR_TIMESTAMP_BEGIN <- x_begin$new_ts
    x_end <- convert_and_qc_timestamp(dsd$CSR_TIMESTAMP_END, tf, tz)
    dsd$CSR_TIMESTAMP_END <- x_end$new_ts
    return(list(dsd = dsd,
                new_ts = 0,
                na_ts = x_begin$na_ts | x_end$na_ts,
                bad_examples = paste(x_begin$bad_examples, x_end$bad_examples, collapse = " ")))

  } else {
    stop("No timestamp begin, mid, or end provided")
  }
}

#' Compute measurement interval for a dataset
#'
#' @param dsd Dataset data (a data frame)
#' @return Median interval between timestamps.
#' @importFrom stats median
#' @keywords internal
#' @note This is used by the reports.
compute_interval <- function(dsd) {
  stopifnot(is.data.frame(dsd))

  dsd <- dsd[with(dsd, order(CSR_TIMESTAMP_BEGIN, CSR_PORT)),]
  dsd$Year <- lubridate::year(dsd$CSR_TIMESTAMP_BEGIN)
  mylag <- function(x) c(as.POSIXct(NA), head(x, -1))  # like dplyr::lag()

  results <- list()
  for(y in unique(dsd$Year)) {
    for(p in unique(dsd$CSR_PORT)) {
      d <- dsd[dsd$Year == y & dsd$CSR_PORT == p,]

      # Remove duplicate timestamps - this fouls up the difftime() computation
      d <- d[!duplicated(d$CSR_TIMESTAMP_BEGIN),]

      results[[paste(y, p)]] <-
        tibble(Year = y,
               Port = p,
               N = nrow(d),
               Interval = median(as.numeric(difftime(d$CSR_TIMESTAMP_BEGIN,
                                                     mylag(d$CSR_TIMESTAMP_BEGIN),
                                                     units = "mins")), na.rm = TRUE))
    }
  }

  cosore::rbind_list(results)
}


#' Change "T2", "SM4.5", etc., to "Tx" and "SMx"
#'
#' @param x Vector of dataset names
#' @param prefixes Prefixes
#' @return A transformed vector of names.
#' @keywords internal
TSM_change <- function(x, prefixes = c("CSR_T", "CSR_SM")) {
  stopifnot(is.character(x))
  for(p in prefixes) {
    x <- gsub(paste0("^", p, "[0-9]+[\\.]{0,1}[0-9]*$"), paste0(p, "x"), x)
  }
  x
}


#' Ensure required columns are present; put them first;
#' sort everything else alphabetically.
#'
#' @param dsd Dataset data, a data frame
#' @param required_cols Required column names, a character vector
#' @keywords internal
#' @return The column-sorted data frame.
#' @note Called by \code{\link{read_raw_dataset}}.
rearrange_columns <- function(dsd, required_cols) {
  stopifnot(is.data.frame(dsd))
  stopifnot(is.character(required_cols))

  if(!all(required_cols %in% names(dsd))) {
    stop("Missing required columns: ",
         paste(setdiff(required_cols, names(dsd)), collapse = ", "))
  }

  other <- setdiff(names(dsd), required_cols)
  dsd[c(required_cols, sort(other))]
}

#' Check dataset for name and class consistency with metadata file
#'
#' @param dataset_name Dataset name, character
#' @param dataset An individual dataset
#' @param field_metadata Field metadata file, from \code{inst/extdata/CSR_COLUMN_UNITS.csv}
#' @return A count of how many times each metadata entry appeared in the dataset.
#' @keywords internal
check_dataset_names <- function(dataset_name, dataset, field_metadata) {

  stopifnot(is.character(dataset_name))
  stopifnot(is.list(dataset))
  stopifnot(is.data.frame(field_metadata))

  field_metadata$count <- 0

  for(tab in names(dataset)) {
    dst <- dataset[[tab]]
    if(is.data.frame(dst)) {

      # We have single "Tx" and "SMx" entries in the metadata table, while data have
      # "T0", "SM2", etc. (very dataset-specific, didn't want to have ALL these in
      # the metadata). Handle this
      changed_names <- TSM_change(names(dst))

      # Does every table name appear in the metadata file?
      fm_table <- field_metadata[field_metadata$Table_name == tab,]
      names_found <- changed_names %in% fm_table$Field_name
      if(any(!names_found)) {
        warning(dataset_name, " - ", "fields not found in metadata for table '", tab, "': ",
                paste(names(dst)[!names_found], collapse = ", "))
      }

      # Do all required fields appear in the table?
      requireds <- fm_table$Field_name[fm_table$Required]
      req_found <- requireds %in% names(dst)
      if(any(!req_found)) {
        warning(dataset_name, " - ", "required metadata fields not found for table '", tab, "': ",
                paste(requireds[!req_found], collapse = ", "))

      }

      # Keep track of which metadata file entries appear
      found <- which(field_metadata$Field_name %in% changed_names)
      field_metadata$count[found] <- field_metadata$count[found] + 1
    }
  }
  field_metadata$count
}


#' Convert a vector to numeric, giving an informative warning.
#'
#' @param x Vector
#' @param name Name of object (for warning)
#' @param warn Warn if non-numeric? Logical
#' @return A numeric vector.
#' @keywords internal
convert_to_numeric <- function(x, name, warn = TRUE) {
  stopifnot(is.character(name))
  stopifnot(is.logical(warn))

  # Convert to numeric, reporting any that don't convert
  y <- suppressWarnings(as.numeric(x))  # ensure numeric
  non_num <- which(is.na(y) & !is.na(x))

  if(warn && length(non_num)) {
    warning("Non-numeric values in ", name,  ": ",
            paste(head(x[non_num]), collapse = ", "),
            "... in positions ",
            paste(head(non_num), collapse = ", "))
  }
  y
}


#' Simple function to gather (reshape) data.
#'
#' @param x Data frame to reshape
#' @param gather_cols Names of columns to gather, character vector
#' @param category_col_name Name of resulting category column, character
#' @param value_col_name Name of resulting value column, character
#' @param new_categories Optional new categories to use
#' in place of gathered column names, character vector
#' @note Base R's \code{\link{reshape}} sucks, while \code{gather}
#' brings in \code{tidyr}, which in turn imports \code{dplyr}, ...way too heavy.
#' @return The data frame in long format.
#' @keywords internal
#' @examples
#' cosore:::minigather(cars, c("speed", "dist"), "var", "val")
minigather <- function(x, gather_cols, category_col_name, value_col_name,
                       new_categories = NULL) {
  stopifnot(is.data.frame(x))
  stopifnot(is.character(gather_cols))
  stopifnot(all(gather_cols %in% colnames(x)))
  stopifnot(is.character(category_col_name))
  stopifnot(is.character(value_col_name))

  if(is.null(new_categories)) {
    new_categories <- gather_cols
  }
  stopifnot(identical(length(new_categories), length(gather_cols)))

  results <- list()
  which_gather <- which(names(x) %in% gather_cols)
  nonvarying <- x[-which_gather]
  for(i in seq_along(which_gather)) {
    y <- data.frame(a = new_categories[i],
                    b = x[which_gather[i]],
                    stringsAsFactors = FALSE)
    names(y) <- c(category_col_name, value_col_name)
    results[[i]] <- cbind(nonvarying, y)
  }
  do.call(rbind, results)
}

#' Remove rows with invalid timestamps.
#'
#' @param dsd Dataset data, a \code{data.frame}
#' @param tf Timestamp format, character
#' @param tz Timezone, character
#' @return The data frame with any NA-timestamp rows removed
#' @keywords internal
remove_invalid_timestamps <- function(dsd, tf, tz) {
  stopifnot(is.data.frame(dsd))
  stopifnot(is.character(tf))
  stopifnot(is.character(tz))

  dsd <- dsd[!is.na(dsd$CSR_TIMESTAMP_BEGIN),]
  dsd <- dsd[!is.na(dsd$CSR_TIMESTAMP_END),]

  if(nrow(dsd) == 0) {
    stop("Timestamps could not be parsed with ", tf, " and tz ", tz)
  }
  dsd
}

#' Remove empty (all-NA) columns from a data frame.
#'
#' @param x The data frame
#' @return The data frame with all-empty columns removed.
#' @keywords internal
remove_empty_columns <- function(x) {
  stopifnot(is.data.frame(x))
  all_na <- vapply(x, function(x) all(is.na(x)), FUN.VALUE = logical(1))
  x[!all_na]
}

#' Make a string (for diagnostics) saying which gases are represented in a dataset
#'
#' @param dsd Dataset data, a data.frame
#' @return String with gases separated by commas
#' @keywords internal
gases_string <- function(dsd) {
  stopifnot(is.data.frame(dsd))
  co2 <- "CSR_FLUX_CO2" %in% names(dsd) && any(!is.na(dsd$CSR_FLUX_CO2))
  ch4 <- "CSR_FLUX_CH4" %in% names(dsd) && any(!is.na(dsd$CSR_FLUX_CH4))
  paste(c("CO2", "CH4")[c(co2, ch4)], collapse = ", ")
}

#' Add port column, if necessary, and convert to numeric.
#'
#' @param dsd Dataset data, a \code{data.frame}
#' @return The data frame with a numeric PORT column.
#' @keywords internal
add_port_column <- function(dsd) {
  stopifnot(is.data.frame(dsd))

  if(!"CSR_PORT" %in% names(dsd) & nrow(dsd)) {
    dsd$CSR_PORT <- 0L
  }
  dsd$CSR_PORT <- as.integer(convert_to_numeric(dsd$CSR_PORT, "CSR_PORT"))
  dsd
}

#' Add NA flux columns, if necessary
#'
#' @param dsd Dataset data, a \code{data.frame}
#' @return The data frame with both CSR_FLUX_CH4 and CSR_FLUX_CO2.
#' @keywords internal
add_flux_columns <- function(dsd) {
  stopifnot(is.data.frame(dsd))

  if(!"CSR_FLUX_CO2" %in% names(dsd)) {
    dsd$CSR_FLUX_CO2 <- NA_real_
  }
  if(!"CSR_FLUX_CH4" %in% names(dsd)) {
    dsd$CSR_FLUX_CH4 <- NA_real_
  }
  dsd
}
