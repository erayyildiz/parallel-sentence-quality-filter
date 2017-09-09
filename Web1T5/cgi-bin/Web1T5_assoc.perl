#!/usr/bin/perl
## -*-cperl-*-
## Run simple queries against the Google n-gram database -- association-based ranking
##
$| = 1;

use warnings;
use strict;

use Time::HiRes qw(time);
use DBI;
use DBD::SQLite;
use CGI qw(:standard *table *div);

use lib ".";
use Web1T5_CGI;

## ---- hard-coded configuration items (most config options are now in Web1T5_CGI.pm)
our %AM_list = ("logl" => "log-likelihood",
                "mi" => "mutual information",
                "chisq" => "chi-squared",
                "dice" => "modified Dice",
                "t" => "t-score"); # list of supported association measures + long names

## ---- user options (set through HTML form)
our $Query = "";        # database query
our $Limit = 100;       # number of results that will be displayed
our $Threshold = 40;    # frequency threshold (database contains n-grams with f >= 40 over word types with f >= 200)
our $HideFixed = 0;     # whether fixed elements in result set are shown (0) or not (1)
our $Mode = "help";     # script mode: "help", "search" (standard query), "csv" (CSV table), "xml" (Web service)
our $Method = "logl";   # AM used for ranking: "logl", "mi", "chisq", "t" (default), "dice"
our $Debug = 0;         # debugging mode displays SQL query

## ---- check "mode" parameter now to suppress HTML output in XML mode (and change error messages)
my $mode_param = param("mode");
if ($mode_param) {
  $mode_param = lc($mode_param);
  unless ($mode_param =~ /^(help|search|xml|csv)$/) {
    print header(-status => "400 Bad Request"), "\n";
    exit 0;
  }
  $Mode = $mode_param;
}
our $html_output = ($Mode eq "xml" or $Mode eq "csv") ? 0 : 1;

## ---- print HTML header, page title and query form
if ($html_output) {
  printHtmlHeader("Web1T5_assoc.perl");

  print
    h1("Query Form");

  print
    start_form(-method => "GET", -action => "$RootUrl/Web1T5_assoc.perl"),
    table({-style => "margin: 1em 2em 0em 2em;"},
        Tr(td(b("Search pattern:"), 
              textfield(-name => "query", -value => "", -size => 50, -maxlength => 512),
             ),
           td({-width => 30}, ""),
           td(submit(-name => "mode", -value => "Search"),
              submit(-name => "mode", -value => "CSV"),
              submit(-name => "mode", -value => "XML"),
             ),
          ),
        Tr(td("&bull; display first",
              popup_menu(-name => "limit", -values => [50,100,200,500,1000,10000], -default => 50),
              "N-grams ranked by",
              popup_menu(-name => "method", -values => [sort keys %AM_list], -default => "t",
                         -labels => \%AM_list),
             ),
           td(""), 
           td(submit(-name => "mode", -value => "Help"),
              '&nbsp;&nbsp;',
              checkbox(-name => "debug", -value => "on", -checked => 0, -label => "Debug"),
             ),
          ),
        Tr(td("&bull; frequency threshold", i("f"), "&ge;", 
              popup_menu(-name => "threshold", -values => [40,100,200,500,1000,5000,10000,100000], -default => 40),
              ", show",
              popup_menu(-name => "fixed", -values => ["shown", "hidden"], -default => "shown",
                        -labels => {"shown" => "full n-grams", "hidden" => "collocates only"}),
             ),
           td(""), 
           td(defaults("Reset Form")),
          ),
         ),
    end_form, "\n\n";
}

## ---- read and validate parameters
$Query = param("query") || $Query;
$Query =~ s/^\s+//; $Query =~ s/\s+$//;
my $method_param = param("method");
if ($method_param) {
  htmlError($Mode, "invalid method '$method_param' (use logl, MI, chisq, t or Dice)")
    unless exists $AM_list{lc($method_param)};
  $Method = lc($method_param);
}
my $limit_param = param("limit");
if ($limit_param) {
  htmlError($Mode, "invalid result set limit '$limit_param'")
    unless $limit_param =~ /^[0-9]+$/ and $limit_param >= 1 and $limit_param <= 10000;
  $Limit = int($limit_param);
}
my $threshold_param = param("threshold");
if ($threshold_param) {
  htmlError($Mode, "invalid frequency threshold '$threshold_param'")
    unless $threshold_param =~ /^[0-9]+$/ and $threshold_param >= 40;
  $Threshold = int($threshold_param);
}
my $fixed_param = param("fixed");
if ($fixed_param) {
  if ($fixed_param =~ /hidden/i)   { $HideFixed = 1 }
  elsif ($fixed_param =~ /shown/i) { $HideFixed = 0 }
  else { htmlError($Mode, "invalid behaviour '$fixed_param' for constant elements") }
}
my $debug_param = param("debug") || "";
$Debug = 1 if lc($debug_param) eq "on";

## ---- temporary "under construction" warning
# htmlError($Mode, "THIS VERSION OF THE INTERFACE IS UNDER CONSTRUCTION - PLEASE COME BACK IN A FEW DAYS");

## ---- HELP page
if ($Mode eq "help") {
  print h1("Instructions: Associations"), "\n";
  print p("The", a({-href => "http://www.ldc.upenn.edu/Catalog/CatalogEntry.jsp?catalogId=LDC2006T13", -target => "blank", -class => "external"}, "Google Web 1T 5-Gram Database"),
          "is a collection of frequent 5-grams extracted from approximately 1 trillion words of Web text collected by Google Research.",
          "This Web interface allows you to search an indexed version of the database for collocational patterns such as", code("carrying * to *"),
          "(where", code("*"), "marks collocate positions) and rank them by association strength, using one of four standard association measures.",
          "Click on the", i("Frequency list"), "tab at the top of this page for simple frequency rankings with more flexible display options.",
         ),
         p("Association scores are calculated between each set of collocates (e.g.", i("coals, newcastle").") and the fixed constraint terms (".i("carrying, to"), "in the example above).",
          "Due to the nature of Google's N-gram database, these scores are only rough approximations and their precise numerical values should not be taken too seriously.",
          "Case-folding and some additional normalization of the N-grams have also been performed, so the frequency counts reported in the result tables may occasionally be different from those found in the original Google data.",
          "The normalized N-grams have been indexed in several SQLite databases with a total size of 180 gigabytes.",
          "For any further questions or bug reports, please contact",
          a({-href => "http://purl.org/stefan.evert/", -target => "_blank", -class => "external"}, "Stefan Evert")."."), "\n";
  print h2("Search pattern"), "\n";
  print p("The search pattern consists of up to 5 terms, which represent the elements of an N-gram and must be separated by blanks."), "\n";
  print ul(li(b("collocate")," positions are marked by asterisks", b(code("*")))), "\n";
  print p("All other terms in the search patterns specify constraints for the &quot;fixed&quot; part of the pattern.",
          "Our database query engine supports four different types of constraint terms:"), "\n";
  print ul(li("a", b("literal term"), "matches the specified word form",
              "(e.g.", code("literati"), "&rarr;", i("literati").")"),
           li("a", b("word set"), "matches any of the listed word forms",
              "(e.g.", code("[mouse,mice]"), "&rarr;", i("mouse, mice").")"),
           li(b("wildcard terms"), "use", b(code("%")), "to stand for an arbitrary substring",
              "(e.g.", code("%erati"), "&rarr;", i("maserati, literati, glitterati, ...").")"),
           li("a question mark", b(code("?")), "indicates a", b("skipped token"), "(i.e. an arbitrary word which is not a collocate)"),
          ), "\n";
  print p("Push the", b("Search"), "button to execute your query,", b("Help"), "to display this help page,",
          "or", b("Reset Form"), "to start over from scratch.",
          "The", b("CSV"), "button returns a CSV table suitable for import into a spreadsheet program or database.",
          "The", b("XML"), "button returns the search results in an XML format, allowing this interface to be used as a Web service."), "\n";
  print h2("Options"), "\n";
  print p("You can customise the calculation of association scores and the display format with the option menus below the search pattern:"), "\n";
  print ul(li("select", b("how many N-grams"), "will be displayed (up to 10,000)"),
           li("choose an", b("association measure"), "for the ranking (".i("t-score, MI, modified Dice coefficient, log-likelihood"), "or", i("chi-squared").")"),
           li("only show N-grams above a certain", b("frequency threshold"), "(default: 40)"),
           li("display either", b("full n-grams"), "or only", b("sets of collocates"), "for more concise output"),
           ), "\n";
  print h2("Examples"), "\n";
  print p("The examples below include comments starting with", code("//").", which must not be entered in the search pattern field."), "\n";
  print pre(<<'STOP'), "\n";
interesting *             // what are people most interested in?

* violin                  // '*' at the start of a query is much slower

met ? * [man,woman]       // use '?' to skip determiner etc.

[enjoy,enjoys] ? *        // what do people enjoy?

carrying * to *           // which measures find the expected result?

%ization ? * health       // use with "grouped" display

from * to *               // a classic of Googleology
STOP
  print h1(""), "\n";
  print end_html, "\n";
}
## ---- common preparations for SEARCH and XML operations
else {
  htmlError($Mode, "please enter a search pattern")
    if $Query eq "";
  checkRunningJobs($Mode); # abort if too many request are already being processed
  ## ---- SEARCH operation
  if ($Mode eq "search") {
    my $T0 = time;
    my @results = execute_query();
    my $dT = time - $T0;
    print h1("Results"), "\n";
    print p({-class => "backlink"}, sprintf "%d matches in %.2f seconds", @results+0, $dT), "\n";
    print start_table({-style => "margin: 1em 2em 0em 2em;"}), "\n";
    print Tr(td({-align => "right"}, b(escapeHTML($AM_list{$Method}))),
             td({-width => 10}, ""),
             td({-align => "right"}, b("frequency")),
             td({-width => 20}, ""),
             td({-align => "left"}, b("N-gram"))), "\n";
    foreach my $line (@results) {
      my ($ngram, $score, $freq) = @$line;
      print Tr(td({-align => "right"}, sprintf "%.2f", $score),
               td(),
               td({-align => "right"}, $freq),
               td(),
               td({-align => "left"}, escapeHTML($ngram))), "\n";
    }
    print end_table, "\n";
    print h1(""), "\n";
    print end_html, "\n";
  }
  ## ---- XML Web service
  elsif ($Mode eq "xml") {
    my @results = execute_query();
    print header(-type => "application/xml");
    print '<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>', "\n";
    print "<items>\n";
    foreach my $line (@results) {
      my ($ngram, $score, $freq) = @$line;
      print "<item>\n";
      printf "\t<score>%.2f</score>\n", $score;
      printf "\t<hits>%d</hits>\n", $freq;
      print "\t<word>",escapeHTML($ngram),"</word>\n";
      print "</item>\n";
    }
    print "</items>\n";
  }
  ## ---- CSV table
  elsif ($Mode eq "csv") {
    my @results = execute_query();
    print header(-type => "text/comma-separated-values", -attachment => "Web1T5_associations.csv");
    printf '"%s","%s","%s"%s', $AM_list{$Method}, "frequency", "N-gram", "\n";
    foreach my $line (@results) {
      my ($ngram, $score, $freq) = @$line;
      printf '%.4f,%d,"%s"%s', $score, $freq, $ngram, "\n";
    }
  }
}

exit 0;


## ---- SUB execute_query() ... run query against SQLite database (uses global variables)
sub execute_query {
  ## load vocabulary database (for quoting and optimisation tests)
  my $DBH = DBI->connect("dbi:SQLite:dbname=$VocabFile", "", "", { RaiseError => 1, AutoCommit => 1 });
  $DBH->do("PRAGMA temp_store_directory = ".$DBH->quote($TempDir))
    if $TempDir;
  $DBH->do("PRAGMA synchronous = 0");

  ## parse search pattern into query terms
  my ($N, $LocalID, @QT) = parse_query($Query, $DBH);

  ## validation: query must have 2 to 5 terms, at least on collocate position is required
  htmlError($Mode, "cannot execute $N-gram query (search pattern must have between 2 and 5 terms)")
    unless $N >= 2 and $N <= 5;
  my @collocate_QT = grep { $_->{-type} eq "collocate" } @QT;
  my $n_collocates = @collocate_QT;
  htmlError($Mode, "at least one collocate term (*) required for association list")
    unless $n_collocates > 0;

  ## Association measures compare observed cooccurrence frequency of the set of constraint terms (= w1) and a set of collocates (= w2)
  ## with their expected cooccurrence frequency under an independence hypothesis.
  ## In this approach, the sample size is the total frequency of the constraint terms (in the specified positions), and the
  ## expected frequency is calculated by multiplying the marginal probabilities of all collocate terms.

  ## in order to compute sample size (SS), rewrite query to include only constraint terms + placeholders for other positions
  my @SS_query = map { ($_->{-type} eq "collocate") ? "?" : $_->{-term} } @QT;
  while (@SS_query and $SS_query[0] eq "?") { shift @SS_query }; # remove leading/trailing ? placeholders to use smallest N-gram size
  while (@SS_query and $SS_query[-1] eq "?") { pop @SS_query };

  ## parse the rewritten query, then generate SQL query to calculate sample size 
  my ($SS_N, $SS_LocalID, @SS_QT) = parse_query("@SS_query", $DBH);
  my $sample_size = 0;
  if (@SS_QT == 1) {
    ## if there is just a single term left, we can use frequency information from the vocabulary database inserted by the optimiser
    $sample_size = $SS_QT[0]{-cost};
  }
  else {
    ## otherwise, run SQL query on suitable N-gram database to obtain joint frequency of constraint terms
    my $SS_SQL = make_sql_query(\@SS_QT, ["SUM(f) AS freq"]);
    my @lines = run_sql_query($SS_N, $SS_SQL, $SS_LocalID);
    my $n_lines = @lines;
    htmlError($Mode, "can't determine sample size for association tests (internal error, got $n_lines values)")
      unless $n_lines == 1;
    $sample_size = $lines[0][1]; # second field should be frequency
  }

  ## construct SQL expression for expected frequency (requires multiple joins with vocabulary table)
  my @collocate_freqs = ();
  my @join_tables = ();
  my @join_clauses = ();
  foreach my $QT (@collocate_QT) {
    my $k = $QT->{-K};
    my $id_var = $QT->{-var};
    push @join_tables, "vocabulary AS v$k";
    push @join_clauses, "v$k.id = $id_var";
    push @collocate_freqs, "v$k.f";
  }
  my $expected = "($sample_size * ".join(" * ", map {"($_ / 300e9)"} @collocate_freqs).")"; # assumes corpus size of ca. 300 billion tokens (from frequency of "the")

  ## SQL expression for selected association score
  my $AM = "AM_".uc($Method)."(ngram.f, $expected, $sample_size) + 0.0"; # function returns string, must be converted into numeric datatype
  if ($Method eq "dice") {
    # Dice coefficient is not based on expected and observed frequencies and needs special implementation
    my $collocate_marginal = (@collocate_freqs > 1) ? "MIN(".join(", ", @collocate_freqs).")" : $collocate_freqs[0];
    $AM = "1000 * 2.0 * ngram.f / ($sample_size + $collocate_marginal)";
  }

  ## compile (optimised) SQL query for association list
  my $SQL = make_sql_query(\@QT, ["$AM AS score", "SUM(ngram.f) AS freq"], \@join_tables, \@join_clauses);
  $SQL .= " HAVING freq >= $Threshold"
    if $Threshold;
  $SQL .= " ORDER BY score DESC, freq DESC";
  $SQL .= " LIMIT $Limit"
    if $Limit;

  ## run main SQL query and return result table
  return run_sql_query($N, $SQL, $LocalID);
}

## ---- SUB: $SQL = make_sql_query(\@QT, \@extra_fields [, \@join_tables, \@join_clauses]);
##           ... construct (optimised) SQL query for query terms, also returning $extra_fields (with optional joins)
sub make_sql_query {
  my ($QT_list, $extra_fields, $join_tables, $join_clauses) = @_;
  my @QT = @$QT_list;

  ## collect SQL constraints and reorder them if --optimize has been specified (otherwise -cost values retain original ordering)
  my @SQL_constraints =  map {$_->{-sql}} sort {$a->{-cost} <=> $b->{-cost}} grep {defined $_->{-sql}} @QT;
  htmlError($Mode, "you have to specify at least one lexical item in your query!")
    unless @SQL_constraints > 0;
  my $have_index_term = 0; # explicitly mark where index should be used (otherwise SQLite might make poor choices without ANALYZE)
  foreach my $constraint (@SQL_constraints) {
    if ($constraint =~ /^w[1-5]/) {
      if ($have_index_term) {
        $constraint = "+$constraint"; # explicitly disallow use of index on any but the first SQL constraint
      }
      else {
        $have_index_term = 1;
      }
    }
  }

  ## construct full SQL query (up to GROUP clause)
  my $columns = join(", ", map { $_->{-var} } @QT);
  $columns = join(", ", $columns, @$extra_fields)
    if ref($extra_fields) eq "ARRAY";
  my $tables = "ngrams AS ngram";
  $tables = join(", ", $tables, @$join_tables)
    if ref($join_tables) eq "ARRAY";
  my $constraints = join(" AND ", @SQL_constraints);
  $constraints = join(" AND ", $constraints, @$join_clauses)
    if ref($join_clauses) eq "ARRAY";

  my $SQL = "SELECT $columns FROM $tables WHERE $constraints";
  my $group_vars = join(", ", grep {/^w/} map { $_->{-var} } @QT);
  if ($group_vars) {
    $SQL .= " GROUP BY $group_vars";
  }
  else {
    my @const_vars = map { (/(const[0-9])$/) ? $1 : () } map { $_->{-var} } @QT;
    htmlError($Mode, "can't find constant field for dummy GROUP BY clause (internal error)")
      unless @const_vars > 0;
    $SQL .= " GROUP BY $const_vars[0]";
  }

  return $SQL;
}

## ---- SUB: @rows = run_sql_query($N, $SQL, $LocalID); ... run SQL query on $N-gram database
sub run_sql_query {
  my ($N, $SQL, $LocalID) = @_;
  $LocalID = {}
    unless ref($LocalID) eq "HASH";

  ## check that required database files exist
  my $NgramFile = sprintf $NgramFilePattern, $N;
  htmlError($Mode, "no data available for $N-grams, sorry!",
             "(cannot find the database file '$NgramFile')")
    unless -f $NgramFile;
  htmlError($Mode, "can't find vocabulary database file '$VocabFile' (internal error)")
    unless -f $VocabFile;

  ## open SQLite database files
  my $DBH = DBI->connect("dbi:SQLite:dbname=$NgramFile", "", "", { RaiseError => 1, AutoCommit => 1 });
  $DBH->do("PRAGMA temp_store_directory = ".$DBH->quote($TempDir))
    if $TempDir;
  $DBH->do("PRAGMA synchronous = 0");
  my ($res) = $DBH->selectrow_array("PRAGMA page_size");
  htmlError($Mode, "can't determine page size of $N-gram database file (internal error)")
    unless $res and $res >= 512 and $res <= 32768;
  my $CachePages = int($CacheSize / $res);
  $DBH->do("PRAGMA cache_size = $CachePages");

  ## register Perl callbacks for association measures (syntax: AM_XXX($observed, $expected, $sample_size); )
  $DBH->func("AM_LOGL", 3, sub {
               my ($O, $E, $N) = @_;
               my $N_O = $N - $O;
               my $N_E = $N - $E;
               2 * ($O * log($O / $E) + $N_O * log($N_O / $N_E));
             }, "create_function");
  $DBH->func("AM_MI", 3, sub {
               my ($O, $E, $N) = @_;
               log($O / $E)  / log(2);
             }, "create_function");
  $DBH->func("AM_CHISQ", 3, sub {
               my ($O, $E, $N) = @_;
               ($O-$E) * ($O-$E) / $E; # simple chi-squared approximation = square of z-score
             }, "create_function");
  $DBH->func("AM_T", 3, sub {
               my ($O, $E, $N) = @_;
               ($O - $E)  / sqrt($O);
             }, "create_function");

  ## check file format and ensure that normalization is consistent
  ($res) = $DBH->selectrow_array("SELECT value FROM meta WHERE key = 'n'");
  htmlError($Mode, "'$NgramFile' is not a proper $N-gram database (internal error)")
    unless $res and $res == $N;
  my ($Normalize) = $DBH->selectrow_array("SELECT value FROM meta WHERE key = 'normalize'");
  htmlError($Mode, "format error in '$NgramFile' (internal error)")
    unless defined $Normalize;
  $DBH->do("ATTACH ".$DBH->quote($VocabFile)." AS vocabulary");
  ($res) = $DBH->selectrow_array("SELECT value FROM vocabulary.meta WHERE key = 'normalize'");
  htmlError($Mode, "normalization status of '$VocabFile' doesn't match '$NgramFile' (internal error)")
    unless $res == $Normalize;

  ## show SQL query in debug mode
  if ($Debug) {
    print h2("SQL Query"), "\n";
    print p({-style => "margin-left: 2em; margin-right:1em; font-size: 90%;"},
            code(escapeHTML($SQL)));
    print "\n\n";
  }

  ## execute SQL query (returns table of ID values)
  my $id_table = $DBH->selectall_arrayref($SQL);
  my $n_rows = @$id_table;

  ## translate IDs back to strings using vocabulary database (with local memoization)
  my $id2str_query = $DBH->prepare("SELECT w FROM vocabulary WHERE id = ?");
  my %id2str = ();              # local lookup hash for memoization
  my @lines = ();               # collect output lines to be returned (format: [$ngram, $freq, ...])
  foreach my $row (@$id_table) {
    ## there should be exactly $N terms in each row, plus frequency or other information;
    ## translate their IDs to strings, using vocabulary database and local IDs
    my @str = ();
    for (1 .. $N) {
      my $id = shift @$row;
      if ($id < 0) {
        push @str, $LocalID->{$id} || "???" # negative IDs are special locally defined strings for constant elements
          unless $HideFixed;
      }
      else {
        my $s = $id2str{$id};
        if (not defined $s) {
          $id2str_query->execute($id);
          ($s) = $id2str_query->fetchrow_array;
          $s = "__ERROR__"
            unless defined $s;
          htmlError($Mode, "multiple entries for vocabulary ID #$id (internal error)")
            if $id2str_query->fetchrow_arrayref;
          $id2str{$id} = $s;
        }
        push @str, $s;
      }
    }
    push @lines, ["@str", @$row];
  }

  ## disconnect from database
  undef $id2str_query;
  $DBH->disconnect if $DBH;
  undef $DBH;

  ## return collected results to main program
  return @lines;
}

## ---- SUB: ($N, $localID, @terms) = parse_query($query, $vocab_DBH); ... parse search pattern
sub parse_query {
  my ($query, $DBH) = @_; # $DBH (handle for vocabulary database) is used collect frequency information for query terms with --optimize

  ## check whether strings have been normalized in the database
  my ($normalize) = $DBH->selectrow_array("SELECT value FROM meta WHERE key = 'normalize'");
  htmlError($Mode, "format error in '$VocabFile' (internal error)")
    unless defined $normalize;

  ## split query into terms
  my @Terms = split " ", $query;
  my $N = @Terms;

  ## construct SQL expression for n-gram query
  my @QT = map { { -K => $_ } } 1 .. $N; # query terms in this list contain all relevant information
  my %LocalID = ("-1" => "..");          # negative IDs for special locally defined strings
  foreach my $k (1 .. $N) {
    my $idx = $k - 1;             # array subscript for k-th term
    my $term = $Terms[$idx];
    $QT[$idx]{-term} = $term;
    if ($term =~ /^%+$/) {
      htmlError($Mode, "wildcard-only term '$term' is not allowed (use ? or * instead)");
    }
    if ($term eq "?") {
      $QT[$idx]{-type} = "skip";  # ? = ignore this position (local ID = -1 for placeholder "..")
      $QT[$idx]{-var} = "-1";
    }
    elsif ($term eq "*") {
      $QT[$idx]{-type} = "collocate"; # "*" terms represent collocate positions we're interested in
      $QT[$idx]{-var} = "w$k";    # this position is included in the result table
    }
    else {
      $QT[$idx]{-type} = "lexical";   # other terms are constraints to be matched in the query
      $QT[$idx]{-var} = "-".($k+1)." AS const$k"; # in associations mode, lexical terms are always collapsed => use local ID constant in SQL
      $LocalID{-($k+1)} = $term;      # first query term has local ID -2, second term ID -3, etc.
      my $where_clause = undef;
      my $op = undef;
      if ($term =~ /^\[(.+)\]$/) {
        my @words = grep { s/\s+//; not /^$/ } split /,/, $1; # list of literal word forms, e.g. [mouse,mice]
        @words = map { normalizeString($Mode, $_) } @words
          if $normalize;
        htmlError($Mode, "wildcard '%' not allowed in word list $term")
          if grep {/\%/} @words;
        $op = "IN";
        $where_clause = "WHERE w IN (". join(", ", map {$DBH->quote($_)} @words) . ")";
      }
      else {
        $term = normalizeString($Mode, $term)
          if $normalize;
        $op = ($term =~ /\%/) ? "LIKE" : "=";
        $where_clause = "WHERE w $op ".$DBH->quote($term);
      }
      $QT[$idx]{-sql} = "w$k IN (SELECT id FROM vocabulary $where_clause)";
      ## obtain frequency information from vocabulary database (later used for reordering query terms)
      my ($freq) = $DBH->selectrow_array("SELECT SUM(f) FROM vocabulary $where_clause");
      my $cost = $freq || 0;
      $cost *= 1000 # table data are clustered by w1 => assume random access is 1000 x as expensive (when using index on other fields)
        unless $k == 1;
      $QT[$idx]{-cost} = $cost; # shuffle constraints so that least frequent term come first
    }
  }

  return $N, \%LocalID, @QT;
}

