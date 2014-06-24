use strict;
use warnings;
package App::RecordStream::Operation::pairwise;

our $VERSION = "4.0.4";

use base qw(App::RecordStream::Operation);

use App::RecordStream::InputStream;
use App::RecordStream::Record;
use App::RecordStream::Executor::Getopt;
use App::RecordStream::Executor;

sub init {
  my $this = shift;
  my $args = shift;

  # XXX: I wonder if some of this wants to be refactored into a parent
  # "Pairwise" operation class.  Diff would then be a thin wrapper on that, and
  # also implementable in a custom way, e.g.:
  #
  #   recs-pairwise [--by-line] -MData::Deep -e '{{diff}} = compare($a, $b)' a b
  #   recs-pairwise -k joinkey ... a b
  #
  # -trs, 11 April 2014

  my $executor_options = App::RecordStream::Executor::Getopt->new();
  my $spec = {
    "by-line" => \($this->{BY_LINE}),
    "key|k=s" => \($this->{KEY}),
    $executor_options->arguments(),
  };

  $this->parse_options($args, $spec, ['bundling']);

  die "You must specify either --by-line or --key\n"
    unless $this->{BY_LINE} or $this->{KEY};

  my $operation = $executor_options->get_string($args)
    or die "You must provide an operation snippet\n";

  my $executor = $this->create_executor($operation);

  $this->{'EXECUTOR'}  = $executor;
  $this->{'OPERATION'} = $executor->get_code_ref("operation");

  my $stream_a = shift @$args
    or die "You must provide an 'A' record stream, or - for stdin\n";

  my $stream_b = shift @$args
    or die "You must provide a 'B' record stream, or - for stdin\n";

  die "Only one record stream can be from stdin\n"
    if $stream_a eq "-" and $stream_b eq "-";

  # Let the normal framework handle stream A, we'll take stream B.
  unshift @$args, $stream_a;
  $this->{STREAM_B} = $this->create_stream($stream_b);
}

sub create_executor {
  my $this    = shift;
  my $snippet = shift;

  my $args = {
    operation => {
      code => "\$line++; $snippet",
      arg_names => [qw(A B)],
    },
  };

  my $executor = eval { App::RecordStream::Executor->new($args) };
  if ( not $executor or $@ ) {
    die "FATAL: Problem compiling a snippet: $@";
  }

  $executor->set_executor_method('push_output', sub {
    $this->push_output(@_);
  });

  return $executor;
}

sub push_output {
  my $this = shift;
  for (@_) {
    $this->push_record(
      ref eq 'HASH'
        ? App::RecordStream::Record->new($_)
        : $_
    );
  }
}

sub create_stream {
  my $this = shift;
  my $file = shift;
  return App::RecordStream::InputStream->new(
    $file eq "-"
      ? (FH => \*STDIN)
      : (FILE => $file)
  );
}

sub accept_record {
  my $this   = shift;
  my $record = shift;
  my @pairs;

recs-join --operation '%$d = (A => { %$d }, B => $i->as_hashref);' line line <(recs-fromcsv --header labs-2014-04-04.csv | recs-xform '{{line}} = $line') <(recs-fromcsv --header labs-2014-06-23.csv | recs-xform '{{line}} = $line') | recs-eval -MData::Deep=compare,domPatch2TEXT 'domPatch2TEXT(compare({{A}}, {{B}})) =~ s/\n/ /gr'

  # XXX by line could just number every record and then use join approach...?
  if ($this->{BY_LINE}) {
    my ($A, $B) = ($record, $this->{STREAM_B}->get_record);

    return 1 if $this->{_STREAM_A_DONE} and not ($A or $B);

    @pairs = ($A, $B);
  }
  elsif ($this->{KEY}) {
    ...
  }
  else {
    die "Unknown pairing method!";
  }
  $this->{OPERATION}->(@$_) for @pairs;
  return 1;
}

sub stream_done {
  my $this = shift;
  $this->{_STREAM_A_DONE} = 1;
  $this->accept_record(undef) while not $this->{STREAM_B}->is_done;
}

sub usage {
  my $this    = shift;
  my $message = shift;

  my $options = [
    ["by-line",       "Pair records from A and B line-by-line"],
    ["key|-k <KEY>",  "Pair records from A and B by joining on <KEY>"],
    App::RecordStream::Executor::options_help(),
  ];

  my $args_string = $this->options_string($options);

  return <<USAGE;
$message
Usage: recs-pairwise [arguments] <operation snippet> <file A> <file B>
   __FORMAT_TEXT__
   Takes two record streams as input, either both from files or one from stdin
   by using "-", and .

   By default each line output is a record containing the key "diff" whose
   value is an array of hashes describing the changes.  Passing --as-text changes
   the output to a formatted string describing the changes.

   Lines are only output for changed records by default.  If this is not suitable,
   pass --all to get a line of output for each pair of input lines.

   To preserve one of the input streams and attach diff information to each
   record before outputting it, specify the --passthru option with a value of "A"
   or "B" indicating the stream to preserve.  Diffs are always generated from
   the perspective of A → B.

   If one input stream has more records than the other, empty records are used
   as the diff source/target.

   This command uses Perl's Data::Deep library to produce diffs.  For complex
   further processing such as applying diffs to other records, see the Data::Deep
   documentation (perldoc Data::Deep).
   __FORMAT_TEXT__

Arguments:
$args_string

Examples:
   Diff a records file with a new input stream
      recs-xform '{{index}} = ++\$i' old-records.json | recs-diff --text old-records.json -
USAGE
}

1;
