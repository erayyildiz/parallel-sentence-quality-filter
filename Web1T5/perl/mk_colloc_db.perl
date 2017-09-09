#!/usr/bin/perl
## -*-cperl-*-
## create collocation database from existing ngram databases
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
Usage:  mk_colloc_db.perl [options] collocations.db
Options:
    --force, -f            overwrite existing database file
    --window=<n>, -w <n>   maximal window size (collocational span) [4]
    --vocab=<file>         filename of vocabulary database [vocabulary.dat]
    --ngram=<pattern>      filename pattern for n-gram database [%d-grams.dat]
    --temp=<d>, -t <d>     store temporary files in directory <d> [/tmp]
    --items=<n>, -i <n>    number of collocation items per pass, e.g. "10M" [1M]
    --cache=<s>, -c <s>    RAM cache size for indexing, e.g. "100M" or "4G" [100M]
    --pagesize=<n>, -p <n> database page size in bytes [4096]
    --verbose, -v          print progress information during processing
    --test                 test program with small subset of data
    --help, -h             show this help page

NB: One million collocation items require about 200MB - 400MB of memory, depending
on window size and platform (32bit vs. 64bit).  Make sure that your choice for the
--items option fits well into available RAM.  The RAM cache (--cache) will be used
for indexing the final collocations database when collocation items are no longer
stored in memory, so it is safe to specify a large value here.
STOP

our $Force = 0;
our $Window = 4;
our $VocabFile = "vocabulary.dat";
our $NgramFilePattern = '%d-grams.dat';
our $TempDir = undef;
our $PageSize = 4096; # default: 4 KiB
our $MaxItems = "1M"; # default: approx. 1 million collocation items = 150 - 400 MiB RAM
our $CacheSize = "100M"; # default: 100 MiB (suffixes M and G are allowed)
our $Verbose = 0;
our $Test = 0;
our $Help = 0;

my $ok = GetOptions(
  "force|f" => \$Force,
  "window|win|w=i" => \$Window,
  "vocabulary|vocab|V=s" => \$VocabFile,
  "ngram|N=s" => \$NgramFilePattern,
  "tempdir|temp|t=s" => \$TempDir,
  "items|i=s" => \$MaxItems,
  "cache|c=s" => \$CacheSize,
  "pagesize|page|p=i" => \$PageSize,
  "verbose|v" => \$Verbose,
  "test" => \$Test,
  "help|h" => \$Help,
);

die $USAGE
  unless $ok and @ARGV == 1 and not $Help;
our $DbFile = shift @ARGV;

## global variables
our $DBH = undef; # database handle for the new (collocations) database file
our $VocabDBH = undef;
our @NgramDBH = map {undef} 0 .. 4; # note that $NgramDBH[0] is an unused filler
our @NgramReaderL = map {undef} 0 .. 4; # handles for SQL commands reading out n-gram data
our @NgramReaderR = map {undef} 0 .. 4; # (separate queries for left/right context)
our %LastRow = ();  # $LastRow{R/L}{$win} stores last row obtained from corresponding reader
our $Normalize = 0; # normalisation status (must be consistent between vocabulary and n-gram databases)
our %Marginal = (); # hash containing marginal frequencies for vocabulary IDs
our ($TestMin, $TestMax) = (100_000, 109_999); # range of node/collocate IDs to use with --test
our $ReadCachePages = 16384; # allow a few megabytes of cache for each DB reader
our $LastItemCount = 4_000_000; # estimate for number of collocation items per node word (ca. 4M for type 0)
$LastItemCount = 10_000 # with --test, the first node word will have much fewer collocates
  if $Test;

## validate command-line options
die "Invalid page size: $PageSize bytes (must be multiple of 2 between 512 and 32768)\n"
  unless $PageSize =~ /^(512|1024|2048|4096|8192|16384|32768)$/;
if (uc($MaxItems) =~ /^([0-9]+(?:\.[0-9]+)?)([KMG])$/) {
  my $num = $1;
  my $unit = { "K" => 2**10, "M" => 2**20, "G" => 2**30 }->{$2};
  $MaxItems = $num * $unit; # requested number of items per pass
}
else {
  die "Invalid --items specification: $MaxItems (use e.g. '500k' or '10M')\n"
}
if (uc($CacheSize) =~ /^([0-9]+(?:\.[0-9]+)?)([MG])$/) {
  my $num = $1;
  my $unit = ($2 eq "M") ? 2**20 : 2**30;
  my $total_size = $num * $unit; # requested cache size in bytes
  $CacheSize = int($total_size / ($PageSize + 256)); # corresponding number of pages (allowing some overhead)
  $CacheSize /= ($Window + 1); # split cache evenly between new database (writer) and n-gram databases (random access)
  die "Error: requested cache is too small with $CacheSize pages (at least 1024 pages required)\n"
    unless $CacheSize >= 1024;
}
else {
  die "Invalid cache size specification: $CacheSize (use e.g. '500M' or '4G')\n"
}
die "Error: Window size must be 1, 2, 3 or 4 (to left/right of node word).\n"
  unless $Window =~ /^[1-4]$/;
die "Error: temporary directory '$TempDir' does not exist\n"
  if $TempDir and not -d $TempDir;

## connect to vocabulary and n-gram databases, then determine normalisation status
print "Connecting to n-gram database .";
die "Error: can't file vocabulary database '$VocabFile'\n"
  unless -f $VocabFile;
$VocabDBH = DBI->connect("dbi:SQLite:dbname=$VocabFile", "", "", { RaiseError => 1, AutoCommit => 1 });
print ".";
($Normalize) = $VocabDBH->selectrow_array("SELECT value FROM meta WHERE key = 'normalize'");

foreach my $win_size (1 .. $Window) {
  print ".";
  my $N = $win_size + 1;
  my $NgramFile = sprintf $NgramFilePattern, $N;
  die "Error: $N-gram database file '$NgramFile' is not available.\n"
    unless -f $NgramFile;
  my $dbh = $NgramDBH[$win_size] = DBI->connect("dbi:SQLite:dbname=$NgramFile", "", "", { RaiseError => 1, AutoCommit => 1 });
  $dbh->do("PRAGMA cache_size = $ReadCachePages"); # allow a few MiB of cache for each database connection (for primary B-tree)
  $dbh->do("PRAGMA temp_store_directory = ".$dbh->quote($TempDir)) # just to be on the safe side (should not be needed)
    if $TempDir;
  my ($db_N) = $dbh->selectrow_array("SELECT value FROM meta WHERE key = 'n'");
  die "Error: '$NgramFile' is not a proper $N-gram database.\n"
    unless $db_N and $db_N == $N;
  my ($norm) = $VocabDBH->selectrow_array("SELECT value FROM meta WHERE key = 'normalize'");
  die "Error: normalization status of '$VocabFile' (=$Normalize) doesn't match '$NgramFile' (=$norm)."
    unless $norm == $Normalize;
}
print " ok\n";

## create collocation database file (removing old version if --force was specified)
if (-f $DbFile) {
  die "Database file '$DbFile' already exists, won't overwrite without --force.\n"
    unless $Force;
  print "(removing existing database file '$DbFile')\n";
  unlink $DbFile;
}

print "Creating database '$DbFile' ... ";
$DBH = DBI->connect("dbi:SQLite:dbname=$DbFile", "", "", { RaiseError => 1, AutoCommit => 1 });
$DBH->do("PRAGMA page_size = $PageSize");
$DBH->do("PRAGMA temp_store_directory = ".$DBH->quote($TempDir))
  if $TempDir;
$DBH->do("PRAGMA synchronous = 0");
print "setup ... ";
$DBH->do("CREATE TABLE meta (key TEXT, value TEXT)");
$DBH->do("INSERT INTO meta VALUES ('window', $Window)");
$DBH->do("INSERT INTO meta VALUES ('normalize', $Normalize)");
my $fields = join(", ", "node INTEGER", "collocate INTEGER", "f_node INTEGER", "f_collocate INTEGER", (map {("l$_ INTEGER", "r$_ INTEGER")} 1 .. $Window));
$DBH->do("CREATE TABLE collocations ($fields)");
print "ok\n";

## load marginal frequencies from vocabulary database
print "Loading vocabulary .";
start_timer();
our $vocab_sql = "SELECT id, f FROM vocabulary";
$vocab_sql .= " WHERE id >= $TestMin AND id <= $TestMax"
  if $Test;
our $VST = $VocabDBH->prepare($vocab_sql);
$VST->execute;
print ".";
our $V = 0;
while (my $row = $VST->fetchrow_arrayref) {
  $Marginal{$row->[0]} = $row->[1];
  $V++;
  print "."
    if (($V & 0x7FFFF) == 0);
}
undef $VST;
$VocabDBH->disconnect; # we no longer need the vocabulary database file
printf " %.2fM words in %.1f s\n", $V / 1e6, stop_timer();

## spawn n-gram readers (SQL queries for left / right context)
print "Spawning n-gram readers ";
start_timer();
foreach my $win (1 .. $Window) {
  my $N = $win + 1;
  my $test_filter = ($Test) ? "WHERE w1 >= $TestMin AND w$N >= $TestMin AND w1 <= $TestMax and w$N <= $TestMax" : "";
  # both queries return (node, collocate, freq) triples
  my $sql_R = "SELECT w1, w$N, f FROM ngrams $test_filter ORDER BY w1 ASC";  
  my $sql_L = "SELECT w$N, w1, f FROM ngrams $test_filter ORDER BY w$N ASC";
  print ".";
  $NgramReaderR[$win] = $NgramDBH[$win]->prepare($sql_R);
  $NgramReaderR[$win]->execute;
  $LastRow{R}{$win} = $NgramReaderR[$win]->fetchrow_arrayref; # prefetch first row
  print ".";
  $NgramReaderL[$win] = $NgramDBH[$win]->prepare($sql_L);
  $NgramReaderL[$win]->execute;
  $LastRow{L}{$win} = $NgramReaderL[$win]->fetchrow_arrayref; # prefetch first row
}
print_timer();

## prepare SQL for writing into collocations table
our $STH = $DBH->prepare("INSERT INTO collocations VALUES (?,?,?,?".(",?" x (2 * $Window)).")"); # see CREATE TABLE above

## compile co-occurrence data for each block of node IDs, and insert into collocations database
print "Compiling co-occurrence data ... \n";
my ($from_id, $last_id) = (0, $V-1);
if ($Test) {
  $from_id = $TestMin;
  $last_id = $TestMax;
}
my $pass_count = 0;
my $Entries = 0;
PASS:
while ($from_id <= $last_id) {
  my $n_nodes = int($MaxItems / $LastItemCount); # how many node words we can process in this pass
  $n_nodes = $last_id - $from_id + 1
    if $from_id + $n_nodes > $last_id;
  $n_nodes = 1
    if $n_nodes < 1;
  my $to_id = $from_id + $n_nodes - 1;
  my $progress = ($Test) ? $to_id - $TestMin + 1 : $to_id + 1;
  $pass_count++;
  printf "Pass #%-3d:  #%d .. #%d [%5.2f%s]  ", $pass_count, $from_id, $to_id, 100 * $progress / $V, '%';

  start_timer();
  my %F = map { $_ => {} } $from_id .. $to_id;  # $F{$node_id}{$colloc_id} = [$L1, $R1, $L2, $R2, ...]
  foreach my $win (1 .. $Window) {
    print "<$win> "; # perform linear pass through appropriate n-gram table to extract L<$win> and R<$win> positions
    my $N = $win + 1;
    my $sql = "SELECT w1, w$N, f FROM ngrams WHERE ((+w1 >= $from_id AND +w1 <= $to_id) OR (+w$N >= $from_id AND +w$N <= $to_id))";
    $sql .= " AND (w1 >= $TestMin AND w$N >= $TestMin AND w1 <= $TestMax and w$N <= $TestMax)"
      if $Test;
    my $reader = $NgramDBH[$win]->prepare($sql); # '+' operators above should ensure full linear scan of table
    $reader->execute;
    while (my $row = $reader->fetchrow_arrayref) {
      my ($w1, $w2, $f) = @$row;
      # w1 = node, w2 = collocate => R<win> field
      if ($w1 >= $from_id and $w1 <= $to_id) {
        $F{$w1}{$w2} = [ (0,) x (2 * $Window) ]  # init value: [ L1=0, R1=0, L2=0, R2=0, ... ]
          unless exists $F{$w1}{$w2};
        $F{$w1}{$w2}[ 2*$win - 1 ] += $f;
      }
      # w1 = collocate, w2 = node => L<win> field
      if ($w2 >= $from_id and $w2 <= $to_id) {
        $F{$w2}{$w1} = [ (0,) x (2 * $Window) ]  # init value: [ L1=0, R1=0, L2=0, R2=0, ... ]
          unless exists $F{$w2}{$w1};
        $F{$w2}{$w1}[ 2*$win - 2 ] += $f;
      }      
    }
    undef $reader; # clean up SQL reader handle
  }
  
  print "STORE "; # now store collocations in new database
  my $n_items = 0;
  $DBH->begin_work;
  foreach my $node_id ($from_id .. $to_id) {
    my $node_f = $Marginal{$node_id};
    foreach my $colloc_id (sort {$a <=> $b} keys %{ $F{$node_id} }) {
      my $colloc_f = $Marginal{$colloc_id};
      $STH->execute($node_id, $colloc_id, $node_f, $colloc_f, @{ $F{$node_id}{$colloc_id} });
      $n_items++;
    }
  }
  $DBH->commit;

  my $n_items_10 = 0; # count collocation items for last 10 (or fewer) nodes to update $LastItemCount
  my $last_10 = ($n_nodes >= 10) ? 10 : $n_nodes;
  foreach my $id ( $to_id - $last_10 + 1 .. $to_id ) {
    $n_items_10 += scalar keys %{ $F{$id} };
  }
  $LastItemCount = int($n_items_10 / $last_10) + 1;
  
  print "CLR "; # clear memory cache for collocation items
  %F = ();

  printf " --  %.2fM items in %.1f s\n", $n_items / 1e6, stop_timer();
  $Entries += $n_items;
  $from_id = $to_id + 1;
}
printf "Inserted %.1fM rows for %d node words into collocation database.\n", $Entries / 1e6, $V;

## close n-gram databases (no longer needed)
foreach my $win (1 .. $Window) {
  $NgramDBH[$win]->disconnect;
}

## build indices for node and collocate IDs
print "Building indices ...";
start_timer();
$DBH->do("PRAGMA cache_size = $CacheSize"); # increase RAM cache for indexing
for my $var ("node", "collocate") {
  print " $var";
  $DBH->do("CREATE INDEX collocations_$var ON collocations ($var)");
}
print_timer();

## generate frequency tables for SQL query optimiser
print "Analyzing for optimizations ... ";
start_timer();
$DBH->do("ANALYZE");
print_timer();

$DBH->disconnect;
print "Done.\n>> $DbFile\n";
