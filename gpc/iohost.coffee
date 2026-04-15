
# IOHost — File-backed I/O for CLI modes
#
# Manages input file streams, output file streams, and HalUCP wiring
# for the batch and debug CLI entry points. Handles encoding configuration,
# output routing (to files or stdout), and synchronous input reading.
#
# The GUI uses its own I/O wiring (through <gpc-terminal> component),
# so this module is CLI-only.

fs = require 'fs'
import {HalUCP} from 'gpc/halUCP'

export class IOHost

  # ---------------------------------------------------------------
  # CLI option registration — adds --infileN / --outfileN options.
  # maxCh: highest channel number to generate options for (default 7)
  # ---------------------------------------------------------------
  @addOptions: (cmd, maxCh = 7) ->
    for ch in [0..maxCh]
      cmd.option("--infile#{ch} <file>", "read input for channel #{ch}")
      cmd.option("--outfile#{ch} <file>", "write output for channel #{ch}")
    return cmd

  # ---------------------------------------------------------------
  # Parse channel file options from commander opts object into
  # { inFiles, outFiles } maps suitable for the IOHost constructor.
  # ---------------------------------------------------------------
  @parseChannelOpts: (opts, maxCh = 7) ->
    inFiles = {}
    outFiles = {}
    for ch in [0..maxCh]
      inFiles[ch] = opts["infile#{ch}"] if opts["infile#{ch}"]
      outFiles[ch] = opts["outfile#{ch}"] if opts["outfile#{ch}"]
    return { inFiles, outFiles }

  # ---------------------------------------------------------------
  # Create an IOHost directly from parsed CLI options.
  # ---------------------------------------------------------------
  @fromOpts: (halUCP, opts, maxCh = 7) ->
    { inFiles, outFiles } = IOHost.parseChannelOpts(opts, maxCh)
    new IOHost(halUCP, {
      inFiles
      outFiles
      ebcdic: opts.ebcdic ? false
      verbose: opts.verbose ? false
    })

  constructor: (@halUCP, opts = {}) ->
    @inFiles = opts.inFiles ? {}       # channel -> filename
    @outFiles = opts.outFiles ? {}     # channel -> filename
    @ebcdic = opts.ebcdic ? false
    @verbose = opts.verbose ? false

    @inStreams = {}      # channel -> array of remaining lines
    @outStreams = {}     # channel -> fs write stream

    # Callbacks — set by the entry point to customize output behavior
    # outputCallback(text, channel) — called for each output chunk
    # errorCallback(msg) — called for fatal errors
    @outputCallback = null
    @errorCallback = null

  # Initialize I/O: load symbols into HalUCP, set encoding, open streams, wire callbacks
  init: (symbols, symTypes) ->
    @halUCP.initFromSymbols(symbols, symTypes) if symbols?

    # Override encoding: default to ASCII unless EBCDIC was requested
    unless @ebcdic
      @halUCP.iobufEncoding = 'ascii'

    # Load input files: read all lines up front
    for ch, filePath of @inFiles
      try
        content = fs.readFileSync(filePath, 'utf8')
        @inStreams[ch] = content.split('\n')
        # Remove trailing empty line from final newline
        if @inStreams[ch].length > 0 and @inStreams[ch][@inStreams[ch].length - 1] == ''
          @inStreams[ch].pop()
      catch e
        @fatal "Cannot open input file for channel #{ch}: #{filePath} (#{e.message})"

    # Open output file streams
    for ch, filePath of @outFiles
      try
        @outStreams[ch] = fs.createWriteStream(filePath)
      catch e
        @fatal "Cannot open output file for channel #{ch}: #{filePath} (#{e.message})"

    # Wire HalUCP output callback
    @halUCP.outputCallback = (text, channel) => @handleOutput(text, channel)

  # Route output text to the appropriate destination
  handleOutput: (text, channel) ->
    ch = channel.toString()
    if @outStreams[ch]?
      @outStreams[ch].write(text)
    if @outputCallback?
      @outputCallback(text, channel)
    else
      process.stdout.write text

  # Read one line from file input for the given channel.
  # Returns the raw line text, or null on EOF.
  readInputLine: (channel) ->
    ch = channel.toString()
    if not @inStreams[ch]?
      return null  # no file input for this channel
    if @inStreams[ch].length == 0
      if @verbose
        process.stderr.write "IOHost: Input exhausted on channel #{ch}\n"
      return null
    return @inStreams[ch].shift()

  # Was a --infileN file configured for this channel? (regardless of
  # whether any lines remain to read).
  hasFileConfigured: (channel) ->
    @inFiles[channel.toString()]?

  # Is there an unread line available right now?
  hasFileInput: (channel) ->
    ch = channel.toString()
    return @inStreams[ch]? and @inStreams[ch].length > 0

  # Flush and close all output streams
  close: ->
    for ch, stream of @outStreams
      stream?.end?()

  # Fatal error helper
  fatal: (msg) ->
    if @errorCallback?
      @errorCallback(msg)
    else
      process.stderr.write "FATAL: #{msg}\n"
    process.exit(1)
