#!/usr/bin/perl
## -*-cperl-*-
## Query the Google n-gram collocations database (lookup for node word)
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
                "f" => "frequency",
                "t" => "t-score"); # list of supported association measures + long names

## ---- user options (set through HTML form)
our $Query = "";        # node word to look up in database
our $Limit = 50;        # number of collocates that will be displayed
our $Threshold = 40;    # co-occurrence frequency threshold (database contains n-grams with f >= 40 over word types with f >= 200)
our $Mode = "help";     # script mode: "help", "search" (standard query), "csv" (CSV table), "xml" (Web service)
our $Method = "t";      # AM used for ranking: "logl", "mi", "chisq", "t" (default), "dice"
our $SpanL = 3;         # collocational span: to the left of the node
our $SpanR = 3;         # collocational span: to the right of the node
our $SpanDistribution = 0; # whether to calculate the span distribution
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
  printHtmlHeader("Web1T5_colloc.perl");

  print
    h1("Query Form");

  print
    start_form(-method => "GET", -action => "$RootUrl/Web1T5_colloc.perl"),
    table({-style => "margin: 1em 2em 0em 2em;"},
        Tr(td(b("Node word:"), 
              textfield(-name => "query", -value => "", -size => 40, -maxlength => 100),
             ),
           td({-width => 30}, ""),
           td(submit(-name => "mode", -value => "Search"),
              submit(-name => "mode", -value => "CSV"),
              submit(-name => "mode", -value => "XML"),
             ),
          ),
        Tr(td("&bull; association measure:",
              popup_menu(-name => "method", -values => [sort keys %AM_list], -default => "t",
                         -labels => \%AM_list),
             ),
           td(""), 
           td(submit(-name => "mode", -value => "Help"),
              '&nbsp;&nbsp;',
              checkbox(-name => "debug", -value => "on", -checked => 0, -label => "Debug"),
             ),
          ),
        Tr(td("&bull; collocational span: left",
              popup_menu(-name => "span_left", -values => [0, 1, 2, 3, 4], -default => 3),
              "words, right",
              popup_menu(-name => "span_right", -values => [0, 1, 2, 3, 4], -default => 3),
              "words",
             ),
           td(""), 
           td(defaults("Reset Form")),
          ),
          Tr(td("&bull; display first",
                popup_menu(-name => "limit", -values => [50,100,200,500,1000,10000], -default => 50),
                "collocates with", i("f"), "&ge;", 
                popup_menu(-name => "threshold", -values => [40,100,200,500,1000,5000,10000,100000], -default => 40),
               ),
             td(""), 
             td(checkbox(-name => "span_distribution", -value => "on", -checked => 0, -label => "show span distribution")),
            ),
         ),
    end_form, "\n\n";
}

## ---- read and validate parameters
$Query = param("query") || $Query;
$Query =~ s/^\s+//; $Query =~ s/\s+$//;
if ($Query =~ /\s/) {
  htmlError($Mode, "Node must be a single word ('$Query' is not allowed)");
}
my $method_param = param("method");
if ($method_param) {
  htmlError($Mode, "unknown association measure '$method_param' (use logl, MI, chisq, t or Dice)")
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
my $span_L_param = param("span_left");
if (defined $span_L_param) {
  htmlError($Mode, "invalid left span '$span_L_param' (must be 0, 1, 2, 3 or 4)")
    unless $span_L_param =~ /^[0-4]$/;
  $SpanL = int($span_L_param);
}
my $span_R_param = param("span_right");
if (defined $span_R_param) {
  htmlError($Mode, "invalid right span '$span_R_param' (must be 0, 1, 2, 3 or 4)")
    unless $span_R_param =~ /^[0-4]$/;
  $SpanR = int($span_R_param);
}
my $debug_param = param("debug") || "";
$Debug = 1 if lc($debug_param) eq "on";
my $span_dist_param = param("span_distribution") || "";
$SpanDistribution = 1 if lc($span_dist_param) eq "on";

## ---- temporary "under construction" warning
# htmlError($Mode, "THIS VERSION OF THE INTERFACE IS UNDER CONSTRUCTION - PLEASE COME BACK IN A FEW DAYS");

## ---- HELP page
if ($Mode eq "help") {
  print h1("Instructions: Collocations"), "\n";
  print p("The", a({-href => "http://www.ldc.upenn.edu/Catalog/CatalogEntry.jsp?catalogId=LDC2006T13", -target => "blank", -class => "external"}, "Google Web 1T 5-Gram Database"),
          "is a collection of frequent 5-grams extracted from approximately 1 trillion words of Web text collected by Google Research.",
          "This Web interface determines", b("pseudo-collocations"), "of a given node word, ranked according to one of five standard association measures.",
          ),
        p("Pseudo-collocations are surface collocations in the sense of Firth and Sinclair, i.e. salient co-occurrences within a span of up to 4 words to the left and right of the node word.",
          "Since the Web 1T 5-Gram Database does not record", i("all"), "contexts of a node word, co-occurrence counts have to be approximated from co-occurrences within frequent N-grams, which may introduce a certain bias towards fixed expressions.  It is therefore more appropriate to speak of &ldquo;pseudo-collocations&rdquo; in this case.",
          "The precise numerical values of association scores should not be taken too seriously or compared to data from regular corpora.  However, we expect the collocate rankings to be comparable to those obtained for full surface collocations.",
          "See", a({-href => "http://purl.org/stefan.evert/PUB/Evert2007HSK_extended_manuscript.pdf", -target => "blank", -class => "external"}, "Evert (2008)"), "for a thorough discussion of surface collocations, appropriate co-occurrence counts and the association measures implemented here.",
          ),
        p("Note that case-folding and some additional normalization of the N-grams may have been performed, leading to frequency counts that  are occasionally different from those found in the original Google data.",
          "Co-occurrence frequency data for all possible node-collocation pairs have been been indexed in a SQLite databases with a size of 32 gigabytes, from which they are retrieved by this Web interface.",
          "For any further questions or bug reports, please contact",
          a({-href => "http://purl.org/stefan.evert/", -target => "_blank", -class => "external"}, "Stefan Evert")."."), "\n";
  print h2("Query form &amp; options"), "\n";
  print p("Type a single", b("Node word"), "into the text field at the top,",
          "then push the", b("Search"), "button to display the most salient collocates for this node.",
          "Push", b("Help"), "to display this help page",
          "or", b("Reset Form"), "to start over from scratch.",
          "The", b("CSV"), "button returns a CSV table suitable for import into a spreadsheet program or database.",
          "The", b("XML"), "button returns the search results in an XML format, allowing this interface to be used as a Web service."), "\n";
  print p("You can customise the calculation of association scores, the size of the collocational span, and the display format with the option menus below the node word:"), "\n";
  print ul(
           li("choose an", b("association measure"), "for the ranking (".i("t-score, MI, modified Dice coefficient, log-likelihood, chi-squared"), "or", i("frequency").")"),
           li("specify how many words around the node are included in the", b("collocational span"), "(separate values for left and right span can be set)"),
           li("select", b("how many N-grams"), "will be displayed (up to 10,000)"),
           li("only show N-grams above a certain", b("frequency threshold"), "(default: 40)"),
           li("display the", b("span distribution").", i.e. positions of co-occurrences in the collocational span", br,
              "(in the HTML display, you can click on percentage figures to display the corresponding N-grams in the database)")
           ), "\n";
  print h1(""), "\n";
  print end_html, "\n";
}
## ---- common preparations for SEARCH, CSV and XML operations
else {
  htmlError($Mode, "Please enter a node word")
    if $Query eq "";
  htmlError($Mode, "Collocational span is empty!")
    if $SpanL == 0 and $SpanR == 0;
  checkRunningJobs($Mode); # abort if too many request are already being processed
  my @span_offsets = ((map {"L$_"} reverse 1 .. $SpanL), (map {"R$_"} 1 .. $SpanR)); # must be in same order as returned by execute_query()
  ## ---- SEARCH operation
  if ($Mode eq "search") {
    my $T0 = time;
    my ($node, $node_freq, @results) = execute_query();
    my $dT = time - $T0;
    print h1("Collocates of &ldquo;".escapeHTML($node)."&rdquo; (f=$node_freq)"), "\n";
    if (@results > 0) {
      print p({-class => "backlink"}, sprintf "%d matches in %.2f seconds", @results+0, $dT), "\n";
      print start_table({-style => "margin: 1em 2em 0em 2em;"}), "\n";
      my @header_fields = (
        td({-align => "left"}, b("collocate")),
        td({-width => 20}, ""),
        td({-align => "right"}, b(escapeHTML($AM_list{$Method}))),
        td({-width => 10}, ""),
        td({-align => "right"}, b("frequency")),
        td({-width => 10}, ""),
        td({-align => "right"}, b("expected")),
        );
      push @header_fields,
        td({-width => 20}, ""),
        td({-align => "left"}, 
          b("span distribution (".
            span({-style => "color:red"}, "left").", ". 
            span({-style => "color:blue"}, "right").
            ")"))
        if $SpanDistribution;
      print Tr(@header_fields), "\n";
      foreach my $line (@results) {
        ## print row of result table
        my ($collocate, $score, $freq, $expected_freq, @offset_freqs) = @$line;
        my @row_fields = (
          td({-align => "left"}, escapeHTML($collocate)),
          td(),
          td({-align => "right"}, sprintf "%.2f", $score),
          td(),
          td({-align => "right"}, $freq),
          td(),
          td({-align => "right"}, sprintf "%.1f", $expected_freq),
          );
        if ($SpanDistribution) {
          my @span_dist_items = (); # calculate distribution of matches across collocational span
          my $cell_width = '3em'; # 8 cells (4 left, 4 right) with equal widths; cells outside span are shown in grey
          my $empty_cell = td({-style => "width:$cell_width; padding:0px; background-color:#AAAAAA; text-align:center;"}, '&nbsp;'); # for cells outside span
          ## fill 8 cells with relative frequencies for each position and suitable background colours
          for (1 .. (4 - $SpanL)) { push @span_dist_items, $empty_cell };
          for my $i (0 .. $#offset_freqs) {
            my $offset = ($i < $SpanL) ? -($SpanL - $i) : $i - $SpanL + 1; # offset position wrt. node
            my $border = ""; # mark node position by vertical lines (boundary of cells for offsets -1 and +1)
            $border = "border-right: 2px solid black;"
              if $offset == -1;
            $border = "border-left: 2px solid black;"
              if $offset == 1; 
            my $proportion = $offset_freqs[$i] / $freq;
            my $bgVal = sprintf "%02X", 255 * (1 - $proportion); # white for $prop = 0, maximal saturation for $prop = 1
            my $fg = ($proportion > .6) ? "white" : "black";
            my $bg = ($offset < 0) ? "#FF${bgVal}${bgVal}" : "#${bgVal}${bgVal}FF"; # left span = red, right span = blue
            my @link_query = ($node, ("*") x (abs($offset) - 1), $collocate); # Web1T5_freq query to find most frequent co-oc patterns
            @link_query = reverse @link_query
              if $offset < 0;
            my $link_href = "$RootUrl/Web1T5_freq.perl?mode=Search&threshold=40&query=".url_escape("@link_query");
            push @span_dist_items,
              td({-style => "width:$cell_width; padding:0px; color:$fg; background-color:$bg; text-align:center; $border"}, 
                 a({-href => $link_href, -style => "color:$fg;"},
                   sprintf("%02.0f%s", 100 * $proportion, '%')));
          }
          for (1 .. (4 - $SpanR)) { push @span_dist_items, $empty_cell };
          my $span_dist = table({-style => "table-layout:fixed;"}, Tr(@span_dist_items));
          push @row_fields,
            td(),
            td({-align => "left"}, $span_dist);
        }
        print Tr(@row_fields), "\n";
      }
      print end_table, "\n";
    }
    else {
      print p(b("No collocates found"), "in database for node word &ldquo;".
              b({-class => "fg1"}, escapeHTML($node))."&rdquo;."), "\n";
    }
    print h1(""), "\n";
    print end_html, "\n";
  }
  ## ---- XML Web service
  elsif ($Mode eq "xml") {
    my ($node, $node_freq, @results) = execute_query();
    print header(-type => "application/xml");
    print '<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>', "\n";
    print "<items>\n";
    foreach my $line (@results) {
      my ($collocate, $score, $freq, $expected_freq, @offset_freqs) = @$line;
      print "<item>\n";
      print "\t<word>",escapeHTML($collocate),"</word>\n";
      printf "\t<score>%.2f</score>\n", $score;
      printf "\t<freq>%d</freq>\n", $freq;
      printf "\t<expected>%d</expected>\n", $expected_freq;
      if ($SpanDistribution) {
        print "\t<distribution>\n";
        foreach my $i (0 .. $#offset_freqs) {
          my $offset = $span_offsets[$i];
          $offset =~ tr[RL][+-]; # specify offset as signed integer wrt. node (L2 => -2, R1 => +1)
          printf "\t\t<freq offset=\"%s\">%d</freq>\n", $offset, $offset_freqs[$i];
        }
        print "\t</distribution>\n";
      }
      print "</item>\n";
    }
    print "</items>\n";
  }
  ## ---- CSV table
  elsif ($Mode eq "csv") {
    my ($node, $node_freq, @results) = execute_query();
    htmlError("No collocates found in database for node word '$node'")
      unless @results;
    print header(-type => "text/comma-separated-values", -attachment => "Web1T5_associations.csv");
    printf '"%s","%s","%s","%s","%s"', "node", "collocate", $AM_list{$Method}, "frequency", "expected";
    print ",", join(",", map {"$_"} @span_offsets)
      if $SpanDistribution;
    print "\n";
    foreach my $line (@results) {
      my ($collocate, $score, $freq, $expected_freq, @offset_freqs) = @$line;
      printf '"%s","%s",%.4f,%d,%.2f', $node, $collocate, $score, $freq, $expected_freq;
      print ",", join(",", @offset_freqs)
        if $SpanDistribution;
      print "\n";
    }
  }
}

exit 0;

## ---- SUB execute_query() ... extract collocatins from SQLite database (uses global variables)
sub execute_query {
  ## check that necessary database files exist
  htmlError($Mode, "can't find vocabulary database file '$VocabFile' (internal error)")
    unless -f $VocabFile;
  htmlError($Mode, "can't find collocation database file '$CollocFile' (internal error)")
    unless -f $CollocFile;
  
  ## connect to databases and check meta-information (collocations and vocabulary)
  my $DBH = DBI->connect("dbi:SQLite:dbname=$CollocFile", "", "", { RaiseError => 1, AutoCommit => 1 });
  $DBH->do("PRAGMA temp_store_directory = ".$DBH->quote($TempDir))
    if $TempDir;
  $DBH->do("PRAGMA synchronous = 0");
  my ($page_size) = $DBH->selectrow_array("PRAGMA page_size");
  htmlError($Mode, "Can't determine page size of collocations database file (internal error)")
    unless $page_size and $page_size >= 512 and $page_size <= 32768;
  my $CachePages = int($CacheSize / $page_size);
  $DBH->do("PRAGMA cache_size = $CachePages");

  my ($MaxWindow) = $DBH->selectrow_array("SELECT value FROM meta WHERE key = 'window'");
  htmlError($Mode, "Format error in '$CollocFile' (internal error)")
    unless defined $MaxWindow and $MaxWindow =~ /^[1-4]$/;
  my ($Normalize) = $DBH->selectrow_array("SELECT value FROM meta WHERE key = 'normalize'");
  htmlError($Mode, "Sorry, the collocation database does not include frequency data for the span L$SpanL .. R$SpanR")
    if $SpanL > $MaxWindow or $SpanR > $MaxWindow;
  
  $DBH->do("ATTACH ".$DBH->quote($VocabFile)." AS vocabulary");
  my ($vocab_normalize) = $DBH->selectrow_array("SELECT value FROM vocabulary.meta WHERE key = 'normalize'");
  htmlError($Mode, "Normalization status of '$VocabFile' doesn't match '$CollocFile' (internal error)")
    unless $vocab_normalize == $Normalize;
  
  ## register Perl callbacks for association measures (syntax: AM_XXX($observed, $expected, $sample_size); )
  ## (complication: observed frequency O may be zero (because SQL applies frequency filter at later stage))
  $DBH->func("AM_LOGL", 3, sub {
               my ($O, $E, $N) = @_;
               my $N_O = $N - $O;
               my $N_E = $N - $E;
               my $term1 = ($O > 0) ? $O * log($O / $E) : 0;
               my $term2 = $N_O * log($N_O / $N_E);
               my $G2 = 2 * ($term1 + $term2);
               return ($O > $E) ? $G2 : -$G2;
             }, "create_function");
  $DBH->func("AM_MI", 3, sub {
               my ($O, $E, $N) = @_;
               if ($O > 0) {
                 return log($O / $E)  / log(2);
               }
               else {
                 return -1e99; # "safe" replacement for -Inf
               }
             }, "create_function");
  $DBH->func("AM_CHISQ", 3, sub {
               my ($O, $E, $N) = @_;
               my $X2 = ($O-$E) * ($O-$E) / $E; # simple chi-squared approximation = square of z-score
               return ($O > $E) ? $X2 : -$X2;
             }, "create_function");
  $DBH->func("AM_T", 3, sub {
               my ($O, $E, $N) = @_;
               if ($O > 0) {
                 return ($O - $E)  / sqrt($O);
               }
               else {
                 return -1e99; # "safe" replacement for -Inf                 
               }
             }, "create_function");
  $DBH->func("AM_F", 3, sub {
               my ($O, $E, $N) = @_;
               return $O;
             }, "create_function");

  ## look up node word in vocabulary database
  my $Node = ($Normalize) ? normalizeString($Mode, $Query) : $Query;
  my ($NodeID, $NodeFreq) = $DBH->selectrow_array("SELECT id, f FROM vocabulary WHERE w = ".$DBH->quote($Node));
  return ($Node, 0) # node word not in database -> return empty list
    if not defined $NodeID;

  ## build SQL query for ranked collocation list
  my @cooc_f_terms = ((map {"l$_"} reverse 1 .. $SpanL), (map {"r$_"} 1 .. $SpanR));
  my $cooc_f = join("+", @cooc_f_terms); # SQL term for co-occurrence frequency
  my $span_freqs = ($SpanDistribution) ? ",".join(",", @cooc_f_terms) : ""; # obtain separate frequency information for all fields in span
  my $win_size = $SpanL + $SpanR; # total window size (number of tokens)
  my $sample_size = "500e9"; # assume total sample size of ca. 500 billion tokens covered by n-gram database
  my $expected = "((f_node+0.0) * (f_collocate+0.0) * $win_size) / $sample_size"; # expected frequency (approximation)
  my $AM = "AM_".uc($Method)."($cooc_f, $expected, $sample_size) + 0.0"; # function returns string, convert to numeric datatype
  if ($Method eq "dice") {
    $AM = "(1000 * 2.0 * $cooc_f) / (f_node + f_collocate)"; # does not take window size into account, but seems sensible
  }
  my $sql_query = "SELECT w, $AM AS score, $cooc_f AS f_obs, $expected AS f_exp $span_freqs FROM collocations, vocabulary WHERE node = $NodeID AND vocabulary.id = collocations.collocate AND f_obs >= $Threshold ORDER BY score DESC, f_obs DESC LIMIT $Limit";

  ## show SQL query in debug mode
  if ($Debug and $Mode eq "search") {
    print h2("SQL Query"), "\n";
    print p({-style => "margin-left: 2em; margin-right:1em; font-size: 90%;"},
            code(escapeHTML($sql_query)));
    print "\n\n";
  }

  ## execute SQL query (returns table of ID values)
  my $results = $DBH->selectall_arrayref($sql_query);

  ## disconnect from database
  $DBH->disconnect if $DBH;
  undef $DBH;

  ## return collected results to main program
  return $Node, $NodeFreq, @$results;
}
