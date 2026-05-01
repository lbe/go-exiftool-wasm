package CPANPLUS::Shell;

use strict;

use CPANPLUS::Error;
use CPANPLUS::Configure;
use CPANPLUS::Internals::Constants;

use Module::Load qw[load];
use Params::Check qw[check];
use Locale::Maketext::Simple Class => 'CPANPLUS', Style => 'gettext';

$Params::Check::VERBOSE = 1;

use vars qw[@ISA $SHELL $DEFAULT];

$DEFAULT = SHELL_DEFAULT;


sub import {
    my $class  = shift;
    my $option = shift;

    $SHELL =
        $option
      ? $class . '::' . $option
      : do { my $conf = CPANPLUS::Configure->new()
          or die loc("No configuration available -- aborting") . $/;
        $conf->get_conf('shell') || $DEFAULT;
      };

  EVAL: {
        eval { load $SHELL };

        if ($@) {
            my $err = $@;

            die loc( "Your default shell '%1' is not available: %2",
                $DEFAULT, $err )
              . loc("Check your installation!") . "\n"
              if $SHELL eq $DEFAULT;

            warn loc( "Failed to use '%1': %2", $SHELL, $err ),
              loc( "Switching back to the default shell '%1'", $DEFAULT ),
              "\n";

            $SHELL = $DEFAULT;
            redo EVAL;
        }
    }
    @ISA = ($SHELL);
}

sub which { return $SHELL }

1;

package CPANPLUS::Shell::_Base::ReadLine;

use strict;
use vars qw($AUTOLOAD $TMPL);

use FileHandle;
use CPANPLUS::Error;
use Params::Check qw[check];
use Module::Load::Conditional qw[can_load];
use Locale::Maketext::Simple Class => 'CPANPLUS', Style => 'gettext';

$Params::Check::VERBOSE = 1;

$TMPL = {
    brand          => { default => '',   strict_type => 1 },
    prompt         => { default => '> ', strict_type => 1 },
    pager          => { default => '' },
    backend        => { default => '' },
    term           => { default => '' },
    format         => { default => '' },
    dist_format    => { default => '' },
    remote         => { default => undef },
    noninteractive => { default => '' },
    cache          => { default => [] },
    settings       => {
        default     => { install_all_prereqs => undef },
        no_override => 1
    },
    _old_sigpipe => { default => '', no_override => 1 },
    _old_outfh   => { default => '', no_override => 1 },
    _signals => { default => { INT => {} }, no_override => 1 },
};

for my $key ( keys %$TMPL ) {
    no strict 'refs';
    *{ __PACKAGE__ . "::$key" } = sub {
        my $self = shift;
        $self->{$key} = $_[0] if @_;
        return $self->{$key};
      }
}

sub _init {
    my $class = shift;
    my %hash  = @_;

    my $self = check( $TMPL, \%hash ) or return;

    bless $self, $class;

    $SIG{INT} = $self->_signals->{INT}->{handler} = sub {
        unless ( $self->_signals->{INT}->{count}++ ) {
            warn loc("Caught SIGINT"), "\n";
        }
        else {
            warn loc("Got another SIGINT"), "\n";
            die;
        }
    };

    return $self;
}

sub _show_banner {
    my $self = shift;
    my $cpan = $self->backend;
    my $term = $self->term;

    my $rl_avail =
        ( !$term->isa('CPANPLUS::Shell::_Faked') )
      ? ( -t STDIN )
          ? ( !$self->__is_bad_terminal($term) )
              ? ( $term->ReadLine ne "Term::ReadLine::Stub" )
                    ? loc("enabled")
                    : loc("available (try 'i Term::ReadLine::Perl')")
              : loc("disabled")
          : loc("suppressed")
      : loc("suppressed in batch mode");

    $rl_avail = loc( "ReadLine support %1.", $rl_avail );
    $rl_avail = "\n*** $rl_avail" if ( length($rl_avail) > 45 );

    $self->__print(
        loc(
            "%1 -- CPAN exploration and module installation (v%2)",
            $self->which, $self->which->VERSION()
        ),
        "\n",
        loc("*** Please report bugs to <bug-cpanplus\@rt.cpan.org>."),
        "\n",
        loc(
            "*** Using CPANPLUS::Backend v%1.  %2", $cpan->VERSION, $rl_avail
        ),
        "\n\n"
    );
}

sub __is_bad_terminal {
    my $self = shift;
    my $term = $self->term;

    return unless $^O eq 'MSWin32';

    return $self->term( Term::ReadLine::Stub->new( $self->brand ) );
}

sub _pager_open {
    my $self = shift;
    my $cpan = $self->backend;
    my $cmd  = $cpan->configure_object->get_program('pager') or return;

    $self->_old_sigpipe( $SIG{PIPE} );
    $SIG{PIPE} = 'IGNORE';

    my $fh = new FileHandle;
    unless ( $fh->open("| $cmd") ) {
        error( loc( "could not pipe to %1: %2\n", $cmd, $! ) );
        return;
    }

    $fh->autoflush(1);

    $self->pager($fh);
    $self->_old_outfh( select $fh );

    return $fh;
}

sub _pager_close {
    my $self = shift;
    my $pager = $self->pager or return;

    $pager->close if ( ref($pager) and $pager->can('close') );

    $self->pager(undef);

    select $self->_old_outfh;
    $SIG{PIPE} = $self->_old_sigpipe;

    return 1;
}

{
    my $win32_console;

    sub _term_rowcount {
        my $self = shift;
        my $cpan = $self->backend;
        my %hash = @_;

        my $default;
        my $tmpl = {
            default => {
                default => 25,
                allow   => qr/^\d$/,
                store   => \$default
            }
        };

        check( $tmpl, \%hash ) or return;

        if ( $^O eq 'MSWin32' ) {
            if ( can_load( modules => { 'Win32::Console' => '0.0' } ) ) {
                $win32_console ||= Win32::Console->new();
                my $rows = ( $win32_console->Info )[-1];
                return $rows;
            }

        }
        else {
            local $Module::Load::Conditional::VERBOSE = 0;
            if ( can_load( modules => { 'Term::Size' => '0.0' } ) ) {
                my ( $cols, $rows ) = Term::Size::chars();
                return $rows;
            }
        }
        return $default;
    }
}

{

    sub __print {
        my $self = shift;
        print @_;
    }

    sub __printf {
        my $self = shift;
        my $fmt  = shift;

        $self->__print( sprintf( $fmt, @_ ) );
    }
}

1;


