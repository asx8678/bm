#!/usr/bin/perl
# Runs a program as the leader of a new session and process group: setsid, then exec, so the
# program keeps this pid and its pid is also its process group id. macOS has no setsid binary.
# Used by Bm.Proc to start pi and verification commands (docs/ARCHITECTURE.md, decision D18).
use strict;
use warnings;
use POSIX ();

die "usage: setsid.pl program [args...]\n" unless @ARGV;
POSIX::setsid() or die "setsid failed: $!\n";
exec { $ARGV[0] } @ARGV or die "exec $ARGV[0] failed: $!\n";
