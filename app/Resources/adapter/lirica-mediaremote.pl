#!/usr/bin/perl
use strict;
use warnings;
use DynaLoader;

sub fail {
  my ($message) = @_;
  print STDERR "$message\n";
  exit 1;
}

my $library = shift @ARGV or fail("Bridge path not provided");
my $action = shift @ARGV or fail("Action not provided");
fail("Invalid action") unless $action eq "stream" || $action eq "send" || $action eq "seek";

if ($action eq "send") {
  my $pid = shift @ARGV;
  my $command = shift @ARGV;
  fail("Missing send parameters") unless defined $pid && defined $command;
  $ENV{"LIRICA_MEDIAREMOTE_PID"} = $pid;
  $ENV{"LIRICA_MEDIAREMOTE_COMMAND"} = $command;
} elsif ($action eq "seek") {
  my $pid = shift @ARGV;
  my $seconds = shift @ARGV;
  fail("Missing seek parameters") unless defined $pid && defined $seconds;
  $ENV{"LIRICA_MEDIAREMOTE_PID"} = $pid;
  $ENV{"LIRICA_MEDIAREMOTE_SEEK"} = $seconds;
}
fail("Too many arguments") if defined shift @ARGV;

my $handle = DynaLoader::dl_load_file($library, 0)
  or fail("Failed to load bridge: " . DynaLoader::dl_error());
my $symbol_name = $action eq "stream" ? "lirica_mediaremote_stream" : "lirica_mediaremote_send";
my $symbol = DynaLoader::dl_find_symbol($handle, $symbol_name)
  or fail("Bridge symbol not found: $symbol_name");
DynaLoader::dl_install_xsub("main::run", $symbol);
run();
