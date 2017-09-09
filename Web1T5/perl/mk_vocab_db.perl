#!/usr/bin/perl
## -*-cperl-*-
## create SQLite database with normalised vocabulary
##
$| = 1;
use warnings;
use strict;

use Time::HiRes qw(time);
use FileHandle;
use Getopt::Long;
use DBI;
use DBD::SQLite;

use FindBin qw($Bin);
use lib $Bin;
use Web1T5_Support;

our $USAGE = <<STOP;
Usage:  mk_vocab_db.perl [options] data/1gms/vocab.gz vocabulary.dat
Options:
    --normalize, -n        normalize word forms
    --limit=<n>, -l <n>    process only first <n> entries (for testing)
    --force, -f            overwrite existing database file
    --cache=<s>, -c <s>    set RAM cache size, e.g. "100M" or "4G" (default: 1G)
    --pagesize=<n>, -p <n> database page size in bytes (default: 4096)
    --help, -h             show this help page
STOP

our $Normalize = 0;
our $Limit = undef;
our $Force = 0;
our $PageSize = 4096;  # default: 4 KiB
our $CacheSize = "1G"; # default: 1 GiB (suffixes M and G are allowed)
our $Help = 0;

my $ok = GetOptions(
  "normalize|n" => \$Normalize,
  "limit|l=f" => \$Limit,
  "force|f" => \$Force,
  "cache|c=s" => \$CacheSize,
  "pagesize|page|p=i" => \$PageSize,
  "help|h" => \$Help,
);

die $USAGE
  unless $ok and @ARGV == 2 and not $Help;

die "Invalid page size: $PageSize bytes (must be multiple of 2 between 512 and 32768)\n"
  unless $PageSize =~ /^(512|1024|2048|4096|8192|16384|32768)$/;
if (uc($CacheSize) =~ /^([0-9]+(?:\.[0-9]+)?)([MG])$/) {
  my $num = $1;
  my $unit = ($2 eq "M") ? 2**20 : 2**30;
  my $total_size = $num * $unit; # requested cache size in bytes
  $CacheSize = int($total_size / ($PageSize + 256)); # corresponding number of pages (allowing some overhead)
  die "Error: requested cache is too small with $CacheSize pages (at least 1024 pages required)\n"
    unless $CacheSize >= 1024;
}
else {
  die "Invalid cache size specification: $CacheSize (use e.g. '500M' or '4G')\n"
}

our $InFile = shift @ARGV;
our $DbFile = shift @ARGV;

if (-f $DbFile) {
  die "Database file '$DbFile' already exists, won't overwrite without --force.\n"
    unless $Force;
  print "(removing existing database file '$DbFile')\n";
  unlink $DbFile;
}

print "Connecting to database '$DbFile' ... ";
our $DBH = DBI->connect("dbi:SQLite:dbname=$DbFile", "", "", { RaiseError => 1, AutoCommit => 1 });
$DBH->do("PRAGMA page_size = $PageSize");
$DBH->do("PRAGMA cache_size = $CacheSize");
print "creating tables ... ";
$DBH->do("CREATE TABLE vocabulary (id INTEGER PRIMARY KEY, w TEXT, f INTEGER)");
$DBH->do("CREATE TABLE meta (key TEXT, value TEXT)");
$DBH->do("INSERT INTO meta VALUES ('normalize', $Normalize)");
print "ok\n";

print "Reading vocabulary .";
our $FH = open_file($InFile);
start_timer();
our ($N, $V) = (0, 0);
our %F = ();
while (<$FH>) {
  chomp;
  my ($w, $f) = split /\t/;
  $w = normalize_string($w)
    if $Normalize;
  $V++ unless exists $F{$w};
  $F{$w} += $f;
  $N++;
  print "."
    if (($N & 0x7FFFF) == 0);
  last if $Limit and $N >= $Limit;
}
$FH->close;
printf " %.2fM words in %.1f s\n", $V / 1e6, stop_timer();
print "    [$N word forms reduced to $V after normalization]\n"
  if $Normalize;

print "Sorting by frequency ... ";
start_timer();
our @wf = sort {$F{$b} <=> $F{$a} or $a cmp $b} keys %F;
print_timer();

print "Inserting into database table .";
our $STH = $DBH->prepare("INSERT INTO vocabulary VALUES (?, ?, ?)");
our $ID = 0;
start_timer();
$DBH->begin_work;
foreach my $w (@wf) {
  $STH->execute($ID, $w, $F{$w});
  $ID++;
  print "."
    if (($ID & 0x7FFFF) == 0);
}
print " commit ... ";
$DBH->commit;
undef $STH;
printf "%.2fM records in %.1f s\n", $ID / 1e6, stop_timer();

print "Building index ... ";
start_timer();
$DBH->do("CREATE INDEX vocabulary_w ON vocabulary (w)");
print_timer();

$DBH->disconnect;
print "Done.\n>> $DbFile\n";


