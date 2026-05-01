package CPANPLUS::Error;

use strict;

use Log::Message private => 0;


BEGIN {
    use Exporter;
    use Params::Check qw[check];
    use vars qw[@EXPORT @ISA $ERROR_FH $MSG_FH];

    @ISA    = 'Exporter';
    @EXPORT = qw[cp_error cp_msg error msg];

    my $log = new Log::Message;

    for my $func (@EXPORT) {
        no strict 'refs';

        my $prefix = 'cp_';
        my $name   = $func;
        $name =~ s/^$prefix//g;

        *$func = sub {
            my $msg = shift;

            return unless defined $msg;

            $log->store(
                message => $msg,
                tag     => uc $name,
                level   => $prefix . $name,
                extra   => [@_]
            );
        };
    }

    sub flush {
        my @foo = $log->flush;
        return unless @foo;
        return reverse @foo;
    }

    sub stack {
        return $log->retrieve( chrono => 1 );
    }

    sub stack_as_string {
        my $class = shift;
        my $trace = shift() ? 1 : 0;

        return join $/, map {
                '['
              . $_->tag . '] ['
              . $_->when . '] '
              . (
                  $trace
                ? $_->message . ' ' . $_->longmess
                : $_->message
              );
        } __PACKAGE__->stack;
    }
}


local $| = 1;
$ERROR_FH = \*STDERR;
$MSG_FH   = \*STDOUT;

package Log::Message::Handlers;
use Carp ();

{

    sub cp_msg {
        my $self    = shift;
        my $verbose = shift;

        return if defined $verbose && $verbose == 0;

        my $old_fh = select $CPANPLUS::Error::MSG_FH;

        print '[' . $self->tag . '] ' . $self->message . "\n";
        select $old_fh;

        return;
    }

    sub cp_error {
        my $self    = shift;
        my $verbose = shift;

        return if defined $verbose && $verbose == 0;

        my $old_fh = select $CPANPLUS::Error::ERROR_FH;

        my $cb =
          CPANPLUS::Internals->can('_return_all_objects')
          ? ( CPANPLUS::Internals->_return_all_objects )[0]
          : undef;

        my $debug = $cb ? $cb->configure_object->get_conf('debug') : 0;
        my $msg = '[' . $self->tag . '] ' . $self->message . "\n";

        print $debug ? Carp::shortmess($msg) : $msg . "\n";

        select $old_fh;

        return;
    }
}

1;

