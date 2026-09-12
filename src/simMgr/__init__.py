"""sim -- run and watch the processes that make up a simulated orbiter.

Every avionics box in this tree is a separate process on a set of fixed
UDP-multicast busses (com/bus.civet).  sim starts several of them in
order, watches them, and takes them down again.  It knows nothing about
what an LRU is written in: it runs a command line, watches the process,
reads its output, and reports whether it is up.
"""

__version__ = "1.0.0"
