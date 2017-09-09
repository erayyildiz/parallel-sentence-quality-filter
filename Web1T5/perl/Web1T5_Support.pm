## -*-cperl-*-
## Support module for Web1T5-Easy indexing scripts
##

package Web1T5_Support;

use base qw(Exporter);
our @EXPORT = qw(&normalize_string &normalize_string_query &open_file &start_timer &stop_timer &print_timer);

use warnings;
use strict;

sub normalize_string {
  my $w = shift;
  return $w
    if $w eq "<S>" or $w eq "</S>";
  return "NUM"
    if $w =~ /^[0-9]+(?:,[0-9]{3})*(?:\.[0-9]+)?$/;
  return "-"
     if $w eq "-";
  return "PUN"
    if $w =~ /^(?:[.!?:,;()"']|-+)$/;
  return "UNK"
    unless $w =~ /^(?:[0-9]+-)*'?(?:[A-Za-z]+['-\/])*[A-Za-z]+'?$/;
  return lc($w);
}

## variant of the normalize_string() function used by ngram_query.perl (passes through wildcards)
sub normalize_string_query {
  my $w = shift;
  return $w
    if $w eq "<S>" or $w eq "</S>" or $w eq "NUM" or $w eq "PUN" or $w eq "UNK";
  return "NUM"
    if $w =~ /^[0-9]+(?:,[0-9]{3})*(?:\.[0-9]+)?$/;
  return "-"
    if $w eq "-";
  return "PUN"
    if $w =~ /^(?:[.!?:,;()"']|-+)$/;
  return "UNK"
    unless $w =~ /^(?:[0-9%]+-)*'?(?:[A-Za-z%]+['\/-])*[A-Za-z%]+'?$/;
  return lc($w);
}

sub open_file {
  my $filename = shift;
  die "Error: file '$filename' does not exist.\n"
    unless -f $filename;
  my $fh = new FileHandle;
  if ($filename =~ /\.gz$/) {
    open $fh, "-|", "gzip", "-cd", $filename;
  }
  else {
    open $fh, "<", $filename;
  }
  die "Error: can't open file '$filename' because $!"
    unless defined $fh;
  return $fh;
}

our $StartTime = undef;

sub start_timer {
  $StartTime = time;
}

sub stop_timer {
  return time - $StartTime;
}

sub print_timer {
  my $t = stop_timer();
  printf " %.1f s\n", $t;
  return $t;
}

1;

