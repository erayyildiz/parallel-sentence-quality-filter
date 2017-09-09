## -*-cperl-*-
## Helper and configuration module for Web1T5-Easy Web interface
##

package Web1T5_CGI;

use base qw(Exporter);
our @EXPORT = (
  qw($CacheSize $MaxJobs $Optimize $TempDir $VocabFile $NgramFilePattern $CollocFile $RootUrl $CSS),
  qw(&printSiteMessage &normalizeString &htmlError &checkRunningJobs &printHtmlHeader &url_escape),
  );

use warnings;
use strict;
use CGI qw(:standard *table *div);

my $MiB = 2 ** 20;  # Megabytes, unit for cache size specification
my $GiB = 2 ** 30;  # Gigabytes, unit for cache size specification

###### Web interface configuration ###########################################

our $CacheSize = 100 * $MiB; # size of SQLite database cache
our $MaxJobs = 2;            # max. number of requests to handle at the same time
our $Optimize = 1;           # whether CGI scripts should try to optimize queries
our $TempDir = "/tmp";       # directory for SQLite temporary files (make sure this has enough space!)

our $VocabFile = "vocabulary.dat";      # name of vocabulary database file
our $NgramFilePattern = '%d-grams.dat'; # printf-style pattern for names of n-gram database files
our $CollocFile = "collocations.dat";   # name of collocations database file

our $RootUrl = ".";          # root URL for the CGI scripts (default relative path should usually work)
our $CSS = "http://cogsci.uni-osnabrueck.de/~severt/GOPHER/css/gopher_web_purple.css"; # CSS stylesheet

# printSiteMessage() prints HTML banner with link to host site, contact information, etc.
sub printSiteMessage {
  print
    p({-class => "navigation"},
      "This is the Web interface of the",
      a({-href => 'http://webascorpus.sourceforge.net/PHITE.php?sitesig=FILES&page=FILES_10_Software&subpage=FILES_50_Google_N-Grams', -target => "_blank", -class => "external"}, "Web1T5-Easy package").
      ", using a",
      a({-href => "http://purl.org/stefan.evert/GOPHER/", -target => "_blank", -class => "external"}, "GOPHER"),
      "page design."),
    "\n\n";
  ## example of a custom site message: public Web service at the University of Osnabrueck
  # print
  #   p({-class => "navigation"},
  #     "This service is provided by the",
  #     a({-href => "http://www.cogsci.uos.de/~CL/", -target => "_blank", -class => "external"}, "Computational Linguistics group"),
  #     "at the",
  #     a({-href => "http://www.cogsci.uos.de/", -target => "_blank", -class => "external"}, "Institute of Cognitive Science") .
  #     ", University of Osnabr&uuml;ck"),
  #   "\n\n";
}

###### end of configuration section ##########################################

# normalize strings (if database is in normalized format)
# *** if you have changed the normalization code for the database, you must adjust this subroutine!! ***
sub normalizeString {
  my ($mode, $w) = @_;
  return $w
    if $w eq "<S>" or $w eq "</S>" or $w eq "NUM" or $w eq "PUN" or $w eq "UNK";
  htmlError($mode, "numbers have been removed by normalization - type 'NUM' instead of '$w'")
    if $w =~ /^[0-9]+(?:,[0-9]{3})*(?:\.[0-9]+)?$/;
  return "-"
    if $w eq "-";
  return "PUN"
    if $w =~ /^(?:[.!?:,;()"']|-+)$/;
  htmlError($mode, "cannot search for word '$w' (deleted by normalization)")
    unless $w =~ /^(?:[0-9%]+-)*'?(?:[A-Za-z%]+['\/-])*[A-Za-z%]+'?$/;
  return lc($w);
}

our $html_header_ok = 0; # keep track whether HTML header has already been shown

# htmlError($mode, $line1, $line2, ...) ... display HTML-formatted error message, close page and exit;
# if $mode is "xml" (Web service), the function will just issue a "bad request" response and exit
sub htmlError {
  my ($mode, @message) = @_;
  if ($mode eq "xml") {
    print header(-type => "application/xml", -status => "400 Bad Request"), "\n";
    exit 0;
  }
  else {
    printHtmlHeader()
      unless $html_header_ok;
    print h1(span({-style => "color: red;"}, "Error"));
    print div({-style => "margin: 2em"}, 
              p(span({-style => "color: red; font-weight: bold;"}, "Error:"),
                join("<br>", map {escapeHTML($_)} @message)));
    print end_html;
    exit 0;
  }
}

# checkRunningJobs($mode); ... if too many requests are running already, abort with an error message
sub checkRunningJobs {
  my $mode = shift;
  my $running_queries = grep {/Web1T5/} `ps xww`; # poor man's job management
  if ($running_queries > $MaxJobs) {
    if ($mode eq "xml") {
      print header(-type => "application/xml", -status => "503 Service Unavailable"), "\n";
      exit 0;
    }
    else {
      printHtmlHeader()
        unless $html_header_ok;
      print h1(span({-style => "color: red;"}, "System busy")), "\n";
      print p("Sorry, the system is busy at the moment.",
              b("Please retry your query in a few seconds"), "by reloading this page or pushing the", b("Search"), "button again."), "\n";
      print end_html, "\n";
      exit 0;
    }
  }
}

# printHtmlHeader(["Web1T5_assoc.perl"]); ... 
sub printHtmlHeader {
  my $active_script = (@_) ? shift : $0; # $0 should be the plain name of the active CGI script
  my $have_ngram_db = -f sprintf $NgramFilePattern, 2; # check if 2-grams database is available, at least
  my $have_colloc_db = -f $CollocFile;
  my $freq_link = ($have_ngram_db) ? td(a({-href => "Web1T5_freq.perl"}, "Frequency list")) : td({-class => "space"}, "");
  my $assoc_link = ($have_ngram_db) ? td(a({-href => "Web1T5_assoc.perl"}, "Associations")) : td({-class => "space"}, "");
  my $colloc_link = ($have_colloc_db) ? td(a({-href => "Web1T5_colloc.perl"}, "Collocations")) : td({-class => "space"}, "");
  if ($active_script =~ /Web1T5_freq/) {
    $freq_link = td({-class => "current"}, "Frequency list");
  }
  elsif ($active_script =~ /Web1T5_assoc/) {
    $assoc_link = td({-class => "current"}, "Associations");
  }
  elsif ($active_script =~ /Web1T5_colloc/) {
    $colloc_link = td({-class => "current"}, "Collocations");
  }
  else {
    warn "Internal error: currently active script not recognised ($active_script)\n";
  }
  print
    header(-type => "text/html"), 
    start_html(
      -title => "Google Web 1T 5-Grams Query",
      -style => { "src" => $CSS },
      ),
    "\n";
  print
    div({-class => "navigation"},
        table(
          Tr({-class => "sitenav"},
            td(""),
            $freq_link,
            $assoc_link,
            $colloc_link,
            td({-class => "space"}, ""),
            td({-class => "space"}, "")),
          Tr({-class => "subnav", -align => "center"},
            td({-colspan => 6, -style => "font-weight: bold; font-size: 120%"}, 
                "The Google Web 1T 5-Gram Database &mdash; SQLite Index &amp; Web Interface")),
    )), "\n";
  printSiteMessage();

  $html_header_ok = 1;
}

# encode URL strings for GET queries (gleaned from URI::Escape module)
sub url_escape {
  my $string = shift;
  utf8::encode($string) # convert Unicode strings to UTF-8 byte sequence before encoding
    if utf8::is_utf8($string);
  $string =~ s/([^A-Za-z0-9\-_.!~*'()])/sprintf("%%%02X", ord($1))/ge;
  return $string;
}


1;