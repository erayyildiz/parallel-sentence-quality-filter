#!/usr/bin/perl
## -*-cperl-*-
## simple queries against the n-gram database
##
$| = 1;
use warnings;
use strict;

use Time::HiRes qw(time);
use Getopt::Long;
use DBI;
use DBD::SQLite;

use FindBin qw($Bin);
use lib $Bin;
use Web1T5_Support;

our $USAGE = <<STOP;

Usage:  ngram_query.perl [options] '<query>'

The <query> consists of up to 5 whitespace-delimited terms representing
n-gram positions.  Four different types of query terms are supported:

  literati     ...  a specific word form
  [mouse,mice] ...  one of the listed word forms
  %erati       ...  wildcard '%' matches arbitrary substring
  *            ...  an arbitrary word (included in n-gram)
  ?            ...  skipped position (not included in n-gram)

Note that the entire query expression has to be quoted as a single argument.

Options:
    --limit=<k>, -l <k>  display only first <n> n-grams
    --freq=<k>, -f <k>   n-gram frequency threshold (f >= k)
    --group, -g          group different strings matching wildcard terms together
    --collapse, -s       sum over matches of wildcard terms
    --temp <d>, -t <d>   store temporary files in directory <d>
    --vocab=<file>       filename of vocabulary database [vocabulary.dat]
    --ngram=<pattern>    filename pattern for n-gram database [%d-grams.dat]
    --optimize, -o       try to optimize query by rewriting terms (experimental)
    --verbose, -v        print progress and timing information on stderr
    --cache=<s>, -c <s>  set RAM cache size, e.g. "100M" or "4G" (default: 100M)
    --help, -h           show this help page

Examples:

  ngram_query.perl -o -g -f 100 '%ization ? * health'
  [ => "organization .. public health", "specialization .. community health", etc.]

STOP

our $Limit = undef;
our $Threshold = 0;
our $Group = 0;
our $Collapse = 0;
our $TempDir = undef;
our $VocabFile = "vocabulary.dat";
our $NgramFilePattern = '%d-grams.dat';
our $Optimize = 0;
our $Verbose = 0;
our $CacheSize = "100M"; # default: 100 MiB (suffixes M and G are allowed)
our $Help = 0;

Getopt::Long::Configure(qw(noignore_case));
my $ok = GetOptions(
                    "limit|l=i" => \$Limit,
                    "frequency|freq|f=i" => \$Threshold,
                    "group|g" => \$Group,
                    "collapse|s" => \$Collapse,
                    "tempdir|temp|t=s" => \$TempDir,
                    "vocabulary|vocab|V=s" => \$VocabFile,
                    "ngram|N=s" => \$NgramFilePattern,
                    "optimize|o" => \$Optimize,
                    "verbose|v" => \$Verbose,
                    "cache|c=s" => \$CacheSize,
                    "help|h" => \$Help,
                   );

die $USAGE
  unless $ok and @ARGV == 1 and not $Help;
die "Sorry, you can't specify both --group and --collapse!\n"
  if $Group and $Collapse;
our $Query = shift @ARGV;

if (uc($CacheSize) =~ /^([0-9]+(?:\.[0-9]+)?)([MG])$/) {
  my $num = $1;
  my $unit = ($2 eq "M") ? 2**20 : 2**30;
  die "Error: requested cache size $CacheSize is too small (at least 1 MiB required)\n"
    unless $num * $unit >= 2**20;
  $CacheSize = $num * $unit; # requested cache size in bytes
}
else {
  die "Invalid cache size specification: $CacheSize (use e.g. '500M' or '4G')\n"
}

## split query into terms and check whether suitable n-gram database is available
our @Terms = split " ", $Query;
our $N = @Terms;

## n-gram database files (filenames are hard-coded so far)
die "Error: can't file vocabulary database '$VocabFile'\n"
  unless -f $VocabFile;
our $NgramFile = sprintf $NgramFilePattern, $N;
die
  "Sorry, $N-gram query '$Query' cannot be executed:\n",
  "I cannot find the database file '$NgramFile'.\n"
  unless -f $NgramFile;

## open SQLite database files
start_timer("Connecting to database ... ");
our $DBH = DBI->connect("dbi:SQLite:dbname=$NgramFile", "", "", { RaiseError => 1, AutoCommit => 1 });
$DBH->do("PRAGMA temp_store_directory = ".$DBH->quote($TempDir))
  if $TempDir;
$DBH->do("PRAGMA synchronous = 0");
my ($res) = $DBH->selectrow_array("SELECT value FROM meta WHERE key = 'n'");
die "Error: '$NgramFile' is not a proper $N-gram database.\n"
  unless $res and $res == $N;
($res) = $DBH->selectrow_array("PRAGMA page_size");
die "Error: can't determine page size of database file '$NgramFile'.\n"
  unless $res and $res >= 512 and $res <= 32768;
my $CachePages = int($CacheSize / $res);
$DBH->do("PRAGMA cache_size = $CachePages");
our ($Normalize) = $DBH->selectrow_array("SELECT value FROM meta WHERE key = 'normalize'");
die "Error: format error in '$NgramFile' (metadata don't show normalization status).\n"
  unless defined $Normalize;
$DBH->do("ATTACH ".$DBH->quote($VocabFile)." AS vocabulary");
($res) = $DBH->selectrow_array("SELECT value FROM vocabulary.meta WHERE key = 'normalize'");
die "Error: normalization status of '$VocabFile' (=$res) doesn't match '$NgramFile' (=$res)."
  unless $res == $Normalize;
stop_timer("ok");

## construct SQL expression for n-gram query
our @QT = map { { -K => $_ } } 1 .. $N; # query terms contain all relevant information
our %LocalID = ("-1" => "..");          # negative IDs for special locally defined strings 
start_timer("Optimizing query ... ")
  if $Optimize;
foreach my $k (1 .. $N) {
  my $idx = $k - 1;             # array subscript for k-th term
  my $term = $Terms[$idx];
  if ($term eq "?") {
    $QT[$idx]{-type} = "skip";  # ? = ignore this position (local ID = -1 for placeholder "..")
    $QT[$idx]{-var} = "-1";
  }
  else {
    $QT[$idx]{-var} = "w$k";    # all other positions are included in the result
    if ($term eq "*") {
      $QT[$idx]{-type} = "collocate"; # "*" terms represent collocate positions we're interested in
    }
    else {
      $QT[$idx]{-type} = "lexical";   # other terms are constraints to be matched in the query
      my $where_clause = undef;
      my $op = undef;
      if ($term =~ /^\[(.+)\]$/) {
        my @words = grep { s/\s+//; not /^$/ } split /,/, $1; # list of literal word forms, e.g. [mouse,mice]
        @words = map { normalize_string_query($_) } @words
          if $Normalize;
        die "Error: wildcard '%' not allowed in word list $term\n"
          if grep {/\%/} @words;
        $op = "IN";
        $where_clause = "WHERE w IN (". join(", ", map {$DBH->quote($_)} @words) . ")";
      }
      else {
        $term = normalize_string_query($term)
          if $Normalize;
        $op = ($term =~ /\%/) ? "LIKE" : "=";
        $where_clause = "WHERE w $op ".$DBH->quote($term);
      }
      $QT[$idx]{-sql} = "w$k IN (SELECT id FROM vocabulary $where_clause)";
      if ($Optimize) {
        my ($freq) = $DBH->selectrow_array("SELECT SUM(f) FROM vocabulary $where_clause");
        my $cost = $freq || 0;
        $cost /= 1000 # table data are ordered by w1 => assume random access is 1000 x as expensive
          if $k == 1;
        $QT[$idx]{-cost} = $cost; # shuffle constraints so that least frequent term come first
      }
      else {
        $QT[$idx]{-cost} = $k;  # ensures that constraints are kept in original order without --optimize
      }
      if ($op eq "LIKE" or $op eq "IN") {
        if ($Group) {
          $QT[$idx]{-order} = "w$k";
        }
        elsif ($Collapse) {
          $LocalID{-($k+1)} = $term; # first query term has local ID -2, etc.
          $QT[$idx]{-var} = -($k+1); # replace variable by constant (= local ID) in SQL query
        }
      }
    }
  }
}
stop_timer("done")
  if $Optimize;

our @SQL_constraints =  map {$_->{-sql}} sort {$a->{-cost} <=> $b->{-cost}} grep {defined $_->{-sql}} @QT;
die "Sorry, you have to specify at least one lexical item in your query!\n"
  unless @SQL_constraints > 0;
if ($Optimize) {
  my $have_index_term = 0; # explicitly mark where index should be used (otherwise SQLite might make poor choices withou ANALYZE)
  @SQL_constraints = map {
    if (/^w[1-5]/) {
      if ($have_index_term) {
        "+$_"; # explicitly disallow use of index on any but the first SQL constraint
      }
      else {
        $have_index_term = 1;
        $_;
      }
    }
    else {
      $_
    }
  } @SQL_constraints;
}

my $columns = join(", ", map { $_->{-var} } @QT);
my $group_vars = join(", ", grep {/^w/} map { $_->{-var} } @QT);
my $constraints = join(" AND ", @SQL_constraints);
our $SQL = "SELECT $columns, SUM(f) AS freq FROM ngrams WHERE $constraints";
$SQL .= " GROUP BY $group_vars"
  if $group_vars;
$SQL .= " HAVING freq >= $Threshold"
  if $Threshold;
my @order_vars = grep { $_ } map { $_->{-order} } @QT;
push @order_vars, "freq DESC";
$SQL .= " ORDER BY ".join(", ", @order_vars)
  if @order_vars;
$SQL .= " LIMIT $Limit"
  if $Limit;

print STDERR "[[ $SQL ]]\n"
  if $Verbose;

## execute SQL query (returns table of ID values)
start_timer("Executing SQL query ... ");
our $id_table = $DBH->selectall_arrayref($SQL);
our $n_rows = @$id_table;
stop_timer("$n_rows rows");

## translate IDs back to strings using vocabulary database
my @group_ids = map { -1 } 1 .. $N; # keep track of current group by ID values (with -g option)
foreach my $row (@$id_table) {
  my @id = @$row;
  my $f = pop @id;
  if ($Group) {
    my $changed = 0;
    foreach my $i (0 .. $N-1) {
      if ($QT[$i]{-order}) {    # only query terms with this attribute are relevant for grouping
        if ($group_ids[$i] != $id[$i]) {
          $changed++;
          $group_ids[$i] = $id[$i];
        }
      }
    }
    print "\n" if $changed;
  }
  my @w = id2str(@id);
  printf "%12d  %s\n", $f, "@w";
}

## disconnect from database (at end of file to cleanup global variables defined below)
cleanup();

######################################################################

## Translate lexicon ID to string (with memoization)
##   ($s1, $s2, ...) = id2str($id1, $id2, ...)
our $ID2STR_query;              # database statement handle with compiled lookup query
our %ID2STR;
BEGIN { 
  $ID2STR_query = undef;
  %ID2STR = ();
}

sub id2str {
  my @str = ();
  foreach my $id (@_) {
    if ($id < 0) {
      push @str, $LocalID{$id} || "???"; # negative IDs are special locally defined strings
    }
    else {
      my $s = $ID2STR{$id};
      if (not defined $s) {
        $ID2STR_query = $DBH->prepare("SELECT w FROM vocabulary WHERE id = ?")
          unless $ID2STR_query;
        $ID2STR_query->execute($id);
        ($s) = $ID2STR_query->fetchrow_array;
        $s = "__ERROR__"
          unless defined $s;
        die "INTERNAL ERROR: multiple entries for vocabulary ID #$id (aborted)\n"
          if $ID2STR_query->fetchrow_arrayref;
        $ID2STR{$id} = $s;
      }
      push @str, $s;
    }
  }
  return (wantarray) ? @str : shift @str;
}

## Clean up and disconnect from database
sub cleanup {
  undef $ID2STR_query;
  $DBH->disconnect if $DBH;
  undef $DBH;
}
