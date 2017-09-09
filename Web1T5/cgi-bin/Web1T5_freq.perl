#!/usr/bin/perl
## -*-cperl-*-
## Run simple queries against the Google n-gram database
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

## ---- hard-coded configuration options are now in Web1T5_CGI.pm

## ---- user options (set through HTML form)
our $Query = "";        # database query
our $Limit = 100;       # number of results that will be displayed
our $Threshold = 100;   # frequency threshold (database contains n-grams with f >= 40 over word types with f >= 200)
our $Wildcards = "";    # optional values: "group" (for each different filler) or "collapse" (all fillers for each wildcard term)
our $HideFixed = 0;     # whether fixed elements in result set are shown (0) or not (1)
our $Mode = "help";     # script mode: "help", "search" (standard query), "csv" (CSV table), "xml" (Web service)
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


## ---- print HTML header and page title
if ($html_output) {
  printHtmlHeader("Web1T5_freq.perl");

  print
    h1("Query Form");

  print
    start_form(-method => "GET", -action => "$RootUrl/Web1T5_freq.perl"),
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
              "N-grams with frequency &ge; ", 
              popup_menu(-name => "threshold", -values => [40,100,200,500,1000,5000,10000,100000], -default => 100),
             ),
           td(""), 
           td(submit(-name => "mode", -value => "Help"),
              '&nbsp;',
              checkbox(-name => "debug", -value => "on", -checked => 0, -label => "Debug"),
              '&nbsp;',
              checkbox(-name => "optimize", -value => "on", -checked => $Optimize, -label => "Optim."),
             ),
          ),
        Tr(td("&bull; variable elements are",
              popup_menu(-name => "wildcards", -values => ["listed normally", "grouped", "collapsed"], -default => "listed normally"),
              ", constant elements are",
              popup_menu(-name => "fixed", -values => ["shown", "hidden"], -default => "shown"),
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
my $wildcards_param = param("wildcards");
if ($wildcards_param) {
  if ($wildcards_param =~ /normal/i)      { $Wildcards = "" }
  elsif ($wildcards_param =~ /group/i)    { $Wildcards = "group" }
  elsif ($wildcards_param =~ /collapse/i) { $Wildcards = "collapse" }
  else { htmlError($Mode, "invalid wildcards behaviour '$wildcards_param' selected") }
}
my $fixed_param = param("fixed");
if ($fixed_param) {
  if ($fixed_param =~ /hidden/i)   { $HideFixed = 1 }
  elsif ($fixed_param =~ /shown/i) { $HideFixed = 0 }
  else { htmlError($Mode, "invalid behaviour '$fixed_param' for constant elements") }
}
my $debug_param = param("debug") || "";
$Debug = 1 if lc($debug_param) eq "on";
my $optimize_param = param("optimize") || ""; # apparently, parameter is simply undefined if the option is not set
$Optimize = (lc(param("optimize")) eq "on") ? 1 : 0;


## ---- temporary "under construction" warning
# htmlError($Mode, "THIS VERSION OF THE INTERFACE IS UNDER CONSTRUCTION - PLEASE COME BACK IN A FEW DAYS");

## ---- HELP page
if ($Mode eq "help") {
  print h1("Instructions: Frequency list"), "\n";
  print p("The", a({-href => "http://www.ldc.upenn.edu/Catalog/CatalogEntry.jsp?catalogId=LDC2006T13", -target => "blank", -class => "external"}, "Google Web 1T 5-Gram Database"),
          "is a collection of frequent 5-grams extracted from approximately 1 trillion words of Web text collected by Google Research.",
          "This Web interface allows you to run interactive queries on an indexed version of the database and displays the most frequent N-grams matching a specified search pattern.",
          "If you want to rank matches by their association strength instead, click the", i("Associations"), "tab at the top of this page.",
          "For the Web interface, case-folding and some additional normalization of the N-grams have been performed, so the frequency counts may occasionally be different from those found in the original Google data.",
          "The normalized N-grams have been indexed in several SQLite databases with a total size of 180 gigabytes.",
          "For any further questions or bug reports, please contact",
          a({-href => "http://purl.org/stefan.evert/", -target => "_blank", -class => "external"}, "Stefan Evert")."."), "\n";
  print h2("Search pattern"), "\n";
  print p("The search pattern consists of up to 5 terms, which represent the elements of an N-gram and must be separated by blanks.",
          "Unigram queries are currently not allowed, i.e. you have to specify at least 2 terms.",
          "Our database engine supports five different types of search terms:"), "\n"; 
  print ul(li("a", b("literal term"), "matches the specified word form",
              "(e.g.", code("literati"), "&rarr;", i("literati").")"),
           li("a", b("word set"), "matches any of the listed word forms",
              "(e.g.", code("[mouse,mice]"), "&rarr;", i("mouse, mice").")"),
           li(b("wildcard terms"), "use", b(code("%")), "to stand for an arbitrary substring",
              "(e.g.", code("%erati"), "&rarr;", i("maserati, literati, glitterati, ...").")"),
           li("the asterisk", b(code("*")), "matches an", b("arbitrary word"),
              "(usually the item of interest)"),
           li("a question mark", b(code("?")), "indicates a", b("skipped token").", which will be ignored in the result set"),
          ), "\n";
  print p("Push the", b("Search"), "button to execute your query,", b("Help"), "to display this help page,",
          "or", b("Reset Form"), "to start over from scratch.",
          "The", b("CSV"), "button returns a CSV table suitable for import into a spreadsheet program or database.",
          "The", b("XML"), "button returns the search results in an XML format, allowing this interface to be used as a Web service."), "\n";
  print h2("Options"), "\n";
  print p("You can customise the display format of search results with the option menus below the search pattern:"), "\n";
  print ul(li("select", b("how many N-grams"), "will be displayed (up to 10,000)"),
           li("only show N-grams above a certain", b("frequency threshold"), "(default: 100)"),
           li(b("variable elements"), "in a query (those matching a wildcard term or word set) can be:",
              ul(li(i("listed normally"), "as separate n-grams"),
                 li(i("grouped"), "together, so there is one group for every different word form"),
                 li(i("collapsed"), "by summing over all matching word forms"),
                )),
           li("optionally,", b("constant elements"), "(those matching a literal term, or variable elements that have been collapsed) can be suppressed for more concise output"),
           ), "\n";
  print h2("Examples"), "\n";
  print p("The examples below include comments starting with", code("//").", which must not be entered in the search pattern field."), "\n";
  print pre(<<'STOP'), "\n";
interesting *             // what are people most interested in?

* violin                  // '*' at the start of a query is much slower

met ? * [man,woman]       // use '?' to skip determiner etc.

[enjoy,enjoys] ? *        // what do people enjoy? (use "collapsed" display)

%ization ? * health       // use with "grouped" display

from * to *               // a classic of Googleology

antidisestablishmentarianism ?  // a trick to obtain unigram frequencies
STOP
  print h1(""), "\n";
  print end_html, "\n";
}
## ---- common preparations for SEARCH, XML and CSV operations
else {
  htmlError($Mode, "please enter a search pattern")
    if $Query eq "";
  checkRunningJobs($Mode); # abort if too many request are already being processed
  ## ---- SEARCH operatione
  if ($Mode eq "search") {
    my $T0 = time;
    my @results = execute_query();
    my $dT = time - $T0;
    print h1("Results"), "\n";
    print p({-class => "backlink"}, sprintf "%d matches in %.2f seconds", @results+0, $dT), "\n";
    print start_table({-style => "margin: 1em 2em 0em 2em;"}), "\n";
    foreach my $line (@results) {
      my ($f, $s) = @$line;
      if ($f eq "GROUP") {
        print Tr(td({-colspan => 3}, hr)), "\n";
      } else {
        print Tr(td({-align => "right"}, $f),
                 td({-width => 10}, ""),
                 td({-align => "left"}, escapeHTML($s))), "\n";
      }
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
    my $in_group = 0;
    foreach my $line (@results) {
      my ($f, $s) = @$line;
      if ($f eq "GROUP") {
        print "</group>\n"
          if $in_group;
        print "<group>\n";
        $in_group = 1;
      } else {
        print "<item>\n";
        print "\t<hits>$f</hits>\n";
        print "\t<word>",escapeHTML($s),"</word>\n";
        print "</item>\n";
      }
    }
    print "</group>\n"
      if $in_group;
    print "</items>\n";
  }
  ## ---- CSV table
  elsif ($Mode eq "csv") {
    my @results = execute_query();
    print header(-type => "text/comma-separated-values", -attachment => "Web1T5_frequency_list.csv");
    print '"frequency","N-gram"', "\n";
    foreach my $line (@results) {
      my ($freq, $ngram) = @$line;
      if ($freq eq "GROUP") {
        print '"",""', "\n";
      }
      else {
        printf '%d,"%s"%s', $freq, $ngram, "\n";
      }
    }
  }
}

exit 0;


## ---- SUB execute_query() ... run query against SQLite database (uses global variables)
sub execute_query {
  ## split query into terms and check whether suitable n-gram database is available
  my @Terms = split " ", $Query;
  my $N = @Terms;

  ## n-gram database files (filenames are hard-coded so far)
  htmlError($Mode, "can't find vocabulary database file '$VocabFile' (internal error)")
    unless -f $VocabFile;
  my $NgramFile = sprintf $NgramFilePattern, $N;
  htmlError($Mode, "no data available for $N-grams, sorry!",
             "(cannot find the database file '$NgramFile')")
    unless -f $NgramFile;

  ## open SQLite database files
  my $DBH = DBI->connect("dbi:SQLite:dbname=$NgramFile", "", "", { RaiseError => 1, AutoCommit => 1 });
  $DBH->do("PRAGMA temp_store_directory = ".$DBH->quote($TempDir))
    if $TempDir;
  $DBH->do("PRAGMA synchronous = 0");
  my ($res) = $DBH->selectrow_array("SELECT value FROM meta WHERE key = 'n'");
  htmlError($Mode, "'$NgramFile' is not a proper $N-gram database (internal error)")
    unless $res and $res == $N;
  ($res) = $DBH->selectrow_array("PRAGMA page_size");
  html_Error("can't determine page size of $N-gram database file (internal error)")
    unless $res and $res >= 512 and $res <= 32768;
  my $CachePages = int($CacheSize / $res);
  $DBH->do("PRAGMA cache_size = $CachePages");
  my ($Normalize) = $DBH->selectrow_array("SELECT value FROM meta WHERE key = 'normalize'");
  htmlError($Mode, "format error in '$NgramFile' (internal error)")
    unless defined $Normalize;
  $DBH->do("ATTACH ".$DBH->quote($VocabFile)." AS vocabulary");
  ($res) = $DBH->selectrow_array("SELECT value FROM vocabulary.meta WHERE key = 'normalize'");
  htmlError($Mode, "normalization status of '$VocabFile' doesn't match '$NgramFile' (internal error)")
    unless $res == $Normalize;

  ## construct SQL expression for n-gram query
  my @QT = map { { -K => $_ } } 1 .. $N; # query terms contain all relevant information
  my %LocalID = ("-1" => "..");          # negative IDs for special locally defined strings
  foreach my $k (1 .. $N) {
    my $idx = $k - 1;             # array subscript for k-th term
    my $term = $Terms[$idx];
    if ($term =~ /^%+$/) {
      htmlError($Mode, "wildcard-only term '$term' is not allowed (use ? or * instead)");
    }
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
          @words = map { normalizeString($Mode, $_) } @words
            if $Normalize;
          htmlError($Mode, "wildcard '%' not allowed in word list $term")
            if grep {/\%/} @words;
          $op = "IN";
          $where_clause = "WHERE w IN (". join(", ", map {$DBH->quote($_)} @words) . ")";
        }
        else {
          $term = normalizeString($Mode, $term)
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
        if (($op eq "LIKE" or $op eq "IN") and ($Wildcards eq "group")) {
          $QT[$idx]{-order} = "w$k";
        }
        if (($op eq "=") or ($Wildcards eq "collapse")) {
          $LocalID{-($k+1)} = $term; # first query term has local ID -2, etc.
          $QT[$idx]{-var} = "-".($k+1)." AS const$k"; # replace variable by constant (= local ID) in SQL query
        }
      }
    }
  }

  ## collect SQL constraints and re-order them if --optimize has been specified
  my @SQL_constraints =  map {$_->{-sql}} sort {$a->{-cost} <=> $b->{-cost}} grep {defined $_->{-sql}} @QT;
  htmlError($Mode, "you have to specify at least one lexical item in your query!")
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

  ## construct full SQL query
  my $columns = join(", ", map { $_->{-var} } @QT);
  my $constraints = join(" AND ", @SQL_constraints);
  our $SQL = "SELECT $columns, SUM(f) AS freq FROM ngrams WHERE $constraints";
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
  $SQL .= " HAVING freq >= $Threshold"
    if $Threshold;
  my @order_vars = grep { $_ } map { $_->{-order} } @QT;
  push @order_vars, "freq DESC";
  $SQL .= " ORDER BY ".join(", ", @order_vars)
    if @order_vars;
  $SQL .= " LIMIT $Limit"
    if $Limit;

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
  my @group_ids = map { -1 } 1 .. $N; # keep track of current group by ID values (--group option)
  my @lines = ();                     # collect output lines to be returned (format: [$freq, $ngram] or ["GROUP", $ngram])
  foreach my $row (@$id_table) {
    my @id = @$row;
    my $f = pop @id;
    my $start_group = 0;
    if ($Wildcards eq "group") {
      ## --group option: check whether variable terms are different from previous item
      foreach my $i (0 .. $N-1) {
        if ($QT[$i]{-order}) {    # only query terms with this attribute are relevant for grouping
          if ($group_ids[$i] != $id[$i]) {
            $start_group++;
            $group_ids[$i] = $id[$i];
          }
        }
      }
    }
    ## translate IDs to strings, using vocabulary database and local IDs
    my @str = ();
    foreach my $id (@id) {
      if ($id < 0) {
        push @str, $LocalID{$id} || "???" # negative IDs are special locally defined strings for constant elements
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
    push @lines, ["GROUP", ""]
      if $start_group;
    push @lines, [$f, "@str"];
  }

  ## disconnect from database
  undef $id2str_query;
  $DBH->disconnect if $DBH;
  undef $DBH;

  ## return collected results to main program
  return @lines;
}

