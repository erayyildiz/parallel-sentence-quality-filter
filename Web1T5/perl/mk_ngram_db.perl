#!/usr/bin/perl
## -*-cperl-*-
## create SQLite database with ngram frequencies
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
Usage:  mk_ngram_db.perl [options] 5 5-grams.dat vocabulary.dat data/5gms/*.gz
Options:
    --normalize, -n        normalize word forms
    --limit=<n>, -l <n>    process only first <n> entries of each file (for testing)
    --force, -f            overwrite existing database file
    --temp <d>, -t <d>     store temporary files in directory <d>
    --cache=<s>, -c <s>    set RAM cache size, e.g. "100M" or "4G" (default: 1G)
    --pagesize=<n>, -p <n> database page size in bytes (default: 4096)
    --help, -h             show this help page
STOP

our $Normalize = 0;
our $Limit = undef;
our $Force = 0;
our $TempDir = undef;
our $PageSize = 4096;  # default: 4 KiB
our $CacheSize = "1G"; # default: 1 GiB (suffixes M and G are allowed)
our $Help = 0;

my $ok = GetOptions(
  "normalize|n" => \$Normalize,
  "limit|l=f" => \$Limit,
  "force|f" => \$Force,
  "tempdir|temp|t=s" => \$TempDir,
  "cache|c=s" => \$CacheSize,
  "pagesize|page|p=i" => \$PageSize,
  "help|h" => \$Help,
);

die $USAGE
  unless $ok and @ARGV >= 2 and not $Help;

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

our $Ngram = shift @ARGV;
our $DbFile = shift @ARGV;
our $Vocab = shift @ARGV;
our @Files = @ARGV;

die "Error: $Ngram-grams are not supported (n = 1 .. 5)\n"
  unless $Ngram =~ /^[1-5]$/;
die "Error: temporary directory '$TempDir' does not exist\n"
  if $TempDir and not -d $TempDir;

if (-f $DbFile) {
  die "Database file '$DbFile' already exists, won't overwrite without --force.\n"
    unless $Force;
  print "(removing existing database file '$DbFile')\n";
  unlink $DbFile;
}

print "Connecting to database ... ";
our $DBH = DBI->connect("dbi:SQLite:dbname=$DbFile", "", "", { RaiseError => 1, AutoCommit => 1 });
$DBH->do("PRAGMA page_size = $PageSize");
$DBH->do("PRAGMA cache_size = $CacheSize");
$DBH->do("PRAGMA temp_store_directory = ".$DBH->quote($TempDir))
  if $TempDir;
$DBH->do("PRAGMA synchronous = 0");
print "creating tables ... ";
$DBH->do("CREATE TABLE meta (key TEXT, value TEXT)");
$DBH->do("INSERT INTO meta VALUES ('n', $Ngram)");
$DBH->do("INSERT INTO meta VALUES ('normalize', $Normalize)");
my $fields = join(", ", (map {"w$_ INTEGER"} 1 .. $Ngram), "f INTEGER");
$DBH->do("CREATE TABLE ngrams ($fields)");
$DBH->do("CREATE TABLE ngrams_raw ($fields)")
  if $Normalize and $Ngram > 1;
print "ok\n";

if ($Ngram == 1) {
  ##
  ## special handling for unigram table (just a copy of the vocabulary DB)
  ##
  $DBH->do("ATTACH '$Vocab' AS v");
  my ($vocab_normalized) = $DBH->selectrow_array("SELECT value FROM v.meta WHERE key = 'normalize'");
  die "\nError: normalization status of vocabulary database '$Vocab' does not match requested normalization!\n"
    unless $vocab_normalized == $Normalize;
  print "Copying vocabulary to unigram table ... ";
  start_timer();
  my $rows = $DBH->do("INSERT INTO ngrams (w1, f) SELECT id, f FROM v.vocabulary");
  printf "%.2fM rows in %.1f s\n", $rows / 1e6, stop_timer();
}
else {
  ##
  ## generate n-gram tables for n = 2 .. 5
  ##
  print "Loading vocabulary .";
  start_timer();
  our $VDB = DBI->connect("dbi:SQLite:dbname=$Vocab", "", "", { RaiseError => 1, AutoCommit => 1 });
  my ($vocab_normalized) = $VDB->selectrow_array("SELECT value FROM meta WHERE key = 'normalize'");
  die "\nError: normalization status of vocabulary database '$Vocab' does not match requested normalization!\n"
    unless $vocab_normalized == $Normalize;
  print ".";
  our $VST = $VDB->prepare("SELECT id, w FROM vocabulary");
  $VST->execute;
  print ".";
  our $V = 0;
  our %ID = ();
  while (my $row = $VST->fetchrow_arrayref) {
    $ID{$row->[1]} = $row->[0];
    $V++;
    print "."
      if (($V & 0x7FFFF) == 0);
  }
  undef $VST;
  $VDB->disconnect;
  printf " %.2fM words in %.1f s\n", $V / 1e6, stop_timer();

  our $RawTable = ($Normalize) ? "ngrams_raw" : "ngrams";
  our $STH = $DBH->prepare("INSERT INTO $RawTable VALUES (".("?," x $Ngram)."?)");
  foreach my $File (@Files) {
    print "Processing $File .";
    my $FH = open_file($File);
    my $N = 0;
    start_timer();
    $DBH->begin_work;
    while (<$FH>) {
      chomp;
      my ($ngram, $f) = split /\t/;
      my @wf = split " ", $ngram;
      my $n_wf = @wf;
      ## don't die here! skip with warning
      if ($n_wf != $Ngram) {
        warn "\nWarning: '$ngram' is a $n_wf-gram, but expected $Ngram-gram (line #$., skipped) ";
        next;
      }
      @wf = map {normalize_string($_)} @wf
        if $Normalize;
      my @id = @ID{@wf};
      my $n_errors = grep {not defined $_} @id;
      if ($n_errors > 0) {
        warn "\nWarning: $n_errors unknown strings in '$ngram' (line #$.) ";
        my @errors = grep {not defined $ID{$_}} @wf;
        warn "\n         [@errors]";
        @id = map {(defined $_) ? $_ : $ID{"UNK"}} @id;
      }
      $STH->execute(@id, $f);
      $N++;
      print "." if (($N & 0x3FFFF) == 0);
      last if $Limit and $N >= $Limit;
    }
    $FH->close;
    print " commit ... ";
    $DBH->commit;
    printf "%.2fM %d-grams in %.1f s\n", $N / 1e6, $Ngram, stop_timer();
  }
  undef $STH;

  if ($Normalize) {
    print "Folding normalized n-grams ... ";
    $fields = join(",", map {"w$_"} 1 .. $Ngram);
    start_timer();
    $DBH->do("INSERT INTO ngrams SELECT $fields, SUM(f) AS f FROM $RawTable GROUP BY $fields");
    print " cleanup ... ";
    $DBH->do("DROP TABLE $RawTable");
    print_timer();
  }
}

## 
## common post-processing for unigrams and other n-grams (indexing etc.)
##
for my $n (1 .. $Ngram) {
  print "Building index for w$n ... ";
  start_timer();
  $DBH->do("CREATE INDEX ngrams_w$n ON ngrams (w$n)");
  print_timer();
}

print "Analyzing for optimizations ... ";
start_timer();
$DBH->do("ANALYZE");
print_timer();

$DBH->disconnect;
print "Done.\n>> $DbFile\n";

