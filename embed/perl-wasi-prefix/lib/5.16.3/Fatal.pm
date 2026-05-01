package Fatal;

use 5.008;
use Carp;
use strict;
use warnings;
use Tie::RefHash;
use Config;

use constant PERL510 => ( $] >= 5.010 );

use constant LEXICAL_TAG => q{:lexical};
use constant VOID_TAG    => q{:void};
use constant INSIST_TAG  => q{!};

use constant ERROR_NOARGS    => 'Cannot use lexical %s with no arguments';
use constant ERROR_VOID_LEX  => VOID_TAG . ' cannot be used with lexical scope';
use constant ERROR_LEX_FIRST => LEXICAL_TAG . ' must be used as first argument';
use constant ERROR_NO_LEX    => "no %s can only start with " . LEXICAL_TAG;
use constant ERROR_BADNAME   => "Bad subroutine name for %s: %s";
use constant ERROR_NOTSUB    => "%s is not a Perl subroutine";
use constant ERROR_NOT_BUILT =>
  "%s is neither a builtin, nor a Perl subroutine";
use constant ERROR_NOHINTS => "No user hints defined for %s";

use constant ERROR_CANT_OVERRIDE =>
  "Cannot make the non-overridable builtin %s fatal";

use constant ERROR_NO_IPC_SYS_SIMPLE =>
  "IPC::System::Simple required for Fatalised/autodying system()";

use constant ERROR_IPC_SYS_SIMPLE_OLD =>
"IPC::System::Simple version %f required for Fatalised/autodying system().  We only have version %f";

use constant ERROR_AUTODIE_CONFLICT =>
  q{"no autodie '%s'" is not allowed while "use Fatal '%s'" is in effect};

use constant ERROR_FATAL_CONFLICT =>
  q{"use Fatal '%s'" is not allowed while "no autodie '%s'" is in effect};

use constant ERROR_58_HINTS =>
  q{Non-subroutine %s hints for %s are not supported under Perl 5.8.x};

use constant MIN_IPC_SYS_SIMPLE_VER => 0.12;

our $VERSION = '2.10';

our $Debug ||= 0;

our %_EWOULDBLOCK = ( MSWin32 => 33, );

my $try_EAGAIN =
  ( $^O eq 'linux' and $Config{archname} =~ /hppa|parisc/ ) ? 1 : 0;

my %TAGS = (
    ':io' => [
        qw(:dbm :file :filesys :ipc :socket
          read seek sysread syswrite sysseek )
    ],
    ':dbm'  => [qw(dbmopen dbmclose)],
    ':file' => [
        qw(open close flock sysopen fcntl fileno binmode
          ioctl truncate chmod)
    ],
    ':filesys' => [
        qw(opendir closedir chdir link unlink rename mkdir
          symlink rmdir readlink umask)
    ],
    ':ipc'       => [qw(:msg :semaphore :shm pipe)],
    ':msg'       => [qw(msgctl msgget msgrcv msgsnd)],
    ':threads'   => [qw(fork)],
    ':semaphore' => [qw(semctl semget semop)],
    ':shm'       => [qw(shmctl shmget shmread)],
    ':system'    => [qw(system exec)],

    ':socket' => [
        qw(accept bind connect getsockopt listen recv send
          setsockopt shutdown socketpair)
    ],

    ':default' => [qw(:io :threads)],

    ':v207' => [
        qw(:threads :dbm :filesys :ipc :socket read seek sysread
          syswrite sysseek open close flock sysopen fcntl fileno
          binmode ioctl truncate)
    ],

    ':1.994'    => [qw(:v207)],
    ':1.995'    => [qw(:v207)],
    ':1.996'    => [qw(:v207)],
    ':1.997'    => [qw(:v207)],
    ':1.998'    => [qw(:v207)],
    ':1.999'    => [qw(:v207)],
    ':1.999_01' => [qw(:v207)],
    ':2.00'     => [qw(:v207)],
    ':2.01'     => [qw(:v207)],
    ':2.02'     => [qw(:v207)],
    ':2.03'     => [qw(:v207)],
    ':2.04'     => [qw(:v207)],
    ':2.05'     => [qw(:v207)],
    ':2.06'     => [qw(:v207)],
    ':2.06_01'  => [qw(:v207)],
    ':2.07'     => [qw(:v207)], ':2.08' => [qw(:default)],
    ':2.09'     => [qw(:default)],
    ':2.10'     => [qw(:default)],
);

$TAGS{':all'} = [ keys %TAGS ];

my %Use_defined_or;

@Use_defined_or{
    qw(
      CORE::fork
      CORE::recv
      CORE::send
      CORE::open
      CORE::fileno
      CORE::read
      CORE::readlink
      CORE::sysread
      CORE::syswrite
      CORE::sysseek
      CORE::umask
      )
} = ();

my %Cached_fatalised_sub = ();

my %Package_Fatal = ();

my %Original_user_sub = ();

my %Is_fatalised_sub = ();
tie %Is_fatalised_sub, 'Tie::RefHash';

my $PACKAGE       = __PACKAGE__;
my $PACKAGE_GUARD = "guard $PACKAGE";
my $NO_PACKAGE    = "no $PACKAGE";

sub import {
    my $class         = shift(@_);
    my @original_args = @_;
    my $void          = 0;
    my $lexical       = 0;
    my $insist_hints  = 0;

    my ( $pkg, $filename ) = caller();

    @_ or return;

    if ( $_[0] eq LEXICAL_TAG ) {
        $lexical = 1;
        shift @_;

        if ( @_ == 0 ) {
            push( @_, ':default' );
        }

        if ( grep { $_ eq VOID_TAG } @_ ) {
            croak(ERROR_VOID_LEX);
        }
    }

    if ( grep { $_ eq LEXICAL_TAG } @_ ) {
        croak(ERROR_LEX_FIRST);
    }

    my @fatalise_these = @_;

    my %unload_later;

    my %done_this;

    while ( my $func = shift @fatalise_these ) {

        if ( $func eq VOID_TAG ) {

            $void = 1;

        }
        elsif ( $func eq INSIST_TAG ) {

            $insist_hints = 1;

        }
        elsif ( exists $TAGS{$func} ) {

            push( @fatalise_these, @{ $TAGS{$func} } );

        }
        else {

            my $insist_this;

            if ( $func =~ s/^!// ) {
                $insist_this = 1;
            }

            next if $done_this{$func};

            my $sub = $func;
            $sub = "${pkg}::$sub" unless $sub =~ /::/;

            if ( !$lexical and $^H{$NO_PACKAGE}{$sub} ) {
                croak( sprintf( ERROR_FATAL_CONFLICT, $func, $func ) );
            }

            my $sub_ref =
              $class->_make_fatal( $func, $pkg, $void, $lexical, $filename,
                ( $insist_this || $insist_hints ) );

            $done_this{$func}++;

            $Original_user_sub{$sub} ||= $sub_ref;

            $unload_later{$func} = $sub_ref if $lexical;
        }
    }

    if ($lexical) {

        $^H |= 0x020000;

        push(
            @{ $^H{$PACKAGE_GUARD} },
            autodie::Scope::Guard->new(
                sub {
                    $class->_install_subs( $pkg, \%unload_later );
                }
            )
        );

        $^H{autodie} = "$PACKAGE @original_args";

    }

    return;

}

sub _install_subs {
    my ( $class, $pkg, $subs_to_reinstate ) = @_;

    my $pkg_sym = "${pkg}::";

    while ( my ( $sub_name, $sub_ref ) = each %$subs_to_reinstate ) {

        my $full_path = $pkg_sym . $sub_name;

        no strict 'refs';

        local *__tmp = *{$full_path};

        { no strict; delete $pkg_sym->{$sub_name}; }

        foreach my $slot (qw( SCALAR ARRAY HASH IO )) {
            next unless defined *__tmp{$slot};
            *{$full_path} = *__tmp{$slot};
        }

        if ($sub_ref) {

            no strict;
            *{ $pkg_sym . $sub_name } = $sub_ref;
        }
    }

    return;
}

sub unimport {
    my $class = shift;

    if ( $_[0] ne LEXICAL_TAG ) {
        croak( sprintf( ERROR_NO_LEX, $class ) );
    }

    shift @_;

    my $pkg = (caller)[0];

    my @unimport_these = @_ ? @_ : ':all';

    while ( my $symbol = shift @unimport_these ) {

        if ( $symbol =~ /^:/ ) {

            push( @unimport_these, @{ $TAGS{$symbol} } );

            next;
        }

        my $sub = $symbol;
        $sub = "${pkg}::$sub" unless $sub =~ /::/;

        if ( exists $Package_Fatal{$sub} ) {
            croak( sprintf( ERROR_AUTODIE_CONFLICT, $symbol, $symbol ) );
        }

        $^H{$NO_PACKAGE}{$sub} = 1;

        if ( my $original_sub = $Original_user_sub{$sub} ) {
            $class->_install_subs( $pkg, { $symbol => $original_sub } );
            next;
        }

        $class->_install_subs( $pkg, { $symbol => undef } );

    }

    return;

}

{
    my %tag_cache;

    sub _expand_tag {
        my ( $class, $tag ) = @_;

        if ( my $cached = $tag_cache{$tag} ) {
            return $cached;
        }

        if ( not exists $TAGS{$tag} ) {
            croak "Invalid exception class $tag";
        }

        my @to_process = @{ $TAGS{$tag} };

        my @taglist = ();

        while ( my $item = shift @to_process ) {
            if ( $item =~ /^:/ ) {
                push( @to_process, @{ $TAGS{$item} } );
            }
            else {
                push( @taglist, "CORE::$item" );
            }
        }

        $tag_cache{$tag} = \@taglist;

        return \@taglist;

    }

}

sub fill_protos {
    my $proto = shift;
    my ( $n, $isref, @out, @out1, $seen_semi ) = -1;
    while ( $proto =~ /\S/ ) {
        $n++;
        push( @out1, [ $n, @out ] ) if $seen_semi;
        push( @out, $1 . "{\$_[$n]}" ), next if $proto =~ s/^\s*\\([\@%\$\&])//;
        push( @out, "\$_[$n]" ),       next if $proto =~ s/^\s*([_*\$&])//;
        push( @out, "\@_[$n..\$#_]" ), last if $proto =~ s/^\s*(;\s*)?\@//;
        $seen_semi = 1, $n--, next if $proto =~ s/^\s*;//;
        die "Internal error: Unknown prototype letters: \"$proto\"";
    }
    push( @out1, [ $n + 1, @out ] );
    return @out1;
}

sub write_invocation {
    my ( $core, $call, $name, $void, @args ) = @_;

    return Fatal->_write_invocation( $core, $call, $name, $void,
        0, undef, undef, @args );
}

sub _write_invocation {

    my ( $class, $core, $call, $name, $void, $lexical, $sub, $sref, @argvs ) =
      @_;

    if ( @argvs == 1 ) {

        my @argv = @{ $argvs[0] };
        shift @argv;

        return $class->_one_invocation( $core, $call, $name, $void, $sub,
            !$lexical, $sref, @argv );

    }
    else {
        my $else = "\t";
        my ( @out, @argv, $n );
        while (@argvs) {
            @argv = @{ shift @argvs };
            $n    = shift @argv;

            my $condition = "\@_ == $n";

            if ( @argv and $argv[-1] =~ /#_/ ) {
                $condition = "\@_ >= $n";
            }

            push @out, "${else}if ($condition) {\n";

            $else = "\t} els";

            push @out,
              $class->_one_invocation( $core, $call, $name, $void, $sub,
                !$lexical, $sref, @argv );
        }
        push @out, qq[
            }
            die "Internal error: $name(\@_): Do not expect to get ", scalar(\@_), " arguments";
    ];

        return join '', @out;
    }
}

sub one_invocation {
    my ( $core, $call, $name, $void, @argv ) = @_;

    return Fatal->_one_invocation( $core, $call, $name, $void,
        undef, 1, undef, @argv );

}

sub _one_invocation {
    my ( $class, $core, $call, $name, $void, $sub, $back_compat, $sref, @argv )
      = @_;

    if ( $void and not $back_compat ) {
        Carp::confess("Internal error: :void mode not supported with $class");
    }

    if ($back_compat) {

        if ( $call eq 'CORE::system' ) {
            return q{
                croak("UNIMPLEMENTED: use Fatal qw(system) not supported.");
            };
        }

        local $" = ', ';

        if ($void) {
            return qq/return (defined wantarray)?$call(@argv):
                   $call(@argv) || Carp::croak("Can't $name(\@_)/
              . ( $core ? ': $!' : ', \$! is \"$!\"' ) . '")';
        }
        else {
            return
              qq{return $call(@argv) || Carp::croak("Can't $name(\@_)}
              . ( $core ? ': $!' : ', \$! is \"$!\"' ) . '")';
        }
    }

    my $human_sub_name = $core ? $call : $sub;

    my $use_defined_or;

    my $hints;

    if ($core) {

        $use_defined_or = exists( $Use_defined_or{$call} );

    }
    else {

        require autodie::hints;

        $hints = autodie::hints->get_hints_for($sref);

        $human_sub_name = autodie::hints->sub_fullname($sref);

    }

    if ( $call eq 'CORE::system' ) {

        local $" = ", ";

        return qq{
            my \$retval;
            my \$E;


            {
                local \$@;

                eval {
                    \$retval = IPC::System::Simple::system(@argv);
                };

                \$E = \$@;
            }

            if (\$E) {

                # TODO - This can't be overridden in child
                # classes!

                die autodie::exception::system->new(
                    function => q{CORE::system}, args => [ @argv ],
                    message => "\$E", errno => \$!,
                );
            }

            return \$retval;
        };

    }

    local $" = ', ';

    my $die = qq{
        die $class->throw(
            function => q{$human_sub_name}, args => [ @argv ],
            pragma => q{$class}, errno => \$!,
            context => \$context, return => \$retval,
            eval_error => \$@
        )
    };

    if ( $call eq 'CORE::flock' ) {

        require POSIX;

        local $@;

        my $EWOULDBLOCK =
             eval { POSIX::EWOULDBLOCK(); }
          || $_EWOULDBLOCK{$^O}
          || _autocroak(
"Internal error - can't overload flock - EWOULDBLOCK not defined on this system."
          );
        my $EAGAIN = $EWOULDBLOCK;
        if ($try_EAGAIN) {
            $EAGAIN = eval { POSIX::EAGAIN(); }
              || _autocroak(
"Internal error - can't overload flock - EAGAIN not defined on this system."
              );
        }

        require Fcntl;

        return qq{

            my \$context = wantarray() ? "list" : "scalar";

            # Try to flock.  If successful, return it immediately.

            my \$retval = $call(@argv);
            return \$retval if \$retval;

            # If we failed, but we're using LOCK_NB and
            # returned EWOULDBLOCK, it's not a real error.

            if (\$_[1] & Fcntl::LOCK_NB() and
                (\$! == $EWOULDBLOCK or
                ($try_EAGAIN and \$! == $EAGAIN ))) {
                return \$retval;
            }

            # Otherwise, we failed.  Die noisily.

            $die;

        };
    }

    my $code = qq[
        no warnings qw(unopened uninitialized numeric);

        if (wantarray) {
            my \@results = $call(@argv);
            my \$retval  = \\\@results;
            my \$context = "list";

    ];

    if ( $hints and ( ref( $hints->{list} ) || "" ) eq 'CODE' ) {

        $code .= qq{
            if ( \$hints->{list}->(\@results) ) { $die };
        };
    }
    elsif ( PERL510 and $hints ) {
        $code .= qq{
            if ( \@results ~~ \$hints->{list} ) { $die };
        };
    }
    elsif ($hints) {
        croak sprintf( ERROR_58_HINTS, 'list', $sub );
    }
    else {
        $code .= qq{
            # An empty list, or a single undef is failure
            if (! \@results or (\@results == 1 and ! defined \$results[0])) {
                $die;
            }
        }
    }

    $code .= qq[
            return \@results;
        }
    ];

    $code .= qq{
        my \$retval  = $call(@argv);
        my \$context = "scalar";
    };

    if ( $hints and ( ref( $hints->{scalar} ) || "" ) eq 'CODE' ) {

        return $code .= qq{
            if ( \$hints->{scalar}->(\$retval) ) { $die };
            return \$retval;
        };

    }
    elsif ( PERL510 and $hints ) {
        return $code . qq{

            if ( \$retval ~~ \$hints->{scalar} ) { $die };

            return \$retval;
        };
    }
    elsif ($hints) {
        croak sprintf( ERROR_58_HINTS, 'scalar', $sub );
    }

    return $code . (
        $use_defined_or
        ? qq{

        $die if not defined \$retval;

        return \$retval;

    }
        : qq{

        return \$retval || $die;

    }
    );

}

sub _make_fatal {
    my ( $class, $sub, $pkg, $void, $lexical, $filename, $insist ) = @_;
    my ( $name, $code, $sref, $real_proto, $proto, $core, $call, $hints );
    my $ini = $sub;

    $sub = "${pkg}::$sub" unless $sub =~ /::/;

    if ( not $lexical ) {
        $Package_Fatal{$sub} = 1;
    }

    $name = $sub;
    $name =~ s/.*::// or $name =~ s/^&//;

    warn "# _make_fatal: sub=$sub pkg=$pkg name=$name void=$void\n" if $Debug;
    croak( sprintf( ERROR_BADNAME, $class, $name ) ) unless $name =~ /^\w+$/;

    if ( defined(&$sub) ) {

        if (
            $Package_Fatal{$sub} and do {
                local $@;
                eval { prototype "CORE::$name" };
            }
          )
        {

            $core  = 1;
            $call  = "CORE::$name";
            $proto = prototype $call;

            $sref = \&$sub;

        }
        else {

            $sub = $Is_fatalised_sub{ \&$sub } || $sub;

            $sref  = \&$sub;
            $proto = prototype $sref;
            $call  = '&$sref';
            require autodie::hints;

            $hints = autodie::hints->get_hints_for($sref);

            if ( $insist and not $hints ) {
                croak( sprintf( ERROR_NOHINTS, $name ) );
            }

            $hints ||= autodie::hints::DEFAULT_HINTS();

        }

    }
    elsif ( $sub eq $ini && $sub !~ /^CORE::GLOBAL::/ ) {
        croak( sprintf( ERROR_NOTSUB, $sub ) );

    }
    elsif ( $name eq 'system' ) {

        my $E;

        {
            local $@;

            eval {
                require IPC::System::Simple;
                require autodie::exception::system;
            };
            $E = $@;
        }

        if ($E) { croak ERROR_NO_IPC_SYS_SIMPLE; }

        if ( $IPC::System::Simple::VERSION < MIN_IPC_SYS_SIMPLE_VER ) {
            croak sprintf( ERROR_IPC_SYS_SIMPLE_OLD,
                MIN_IPC_SYS_SIMPLE_VER, $IPC::System::Simple::VERSION );
        }

        $call = 'CORE::system';
        $name = 'system';
        $core = 1;

    }
    elsif ( $name eq 'exec' ) {

        $call = 'CORE::exec';
        $name = 'exec';
        $core = 1;

    }
    else { my $E;
        {
            local $@;
            $proto = eval { prototype "CORE::$name" };
            $E = $@;
        }
        croak( sprintf( ERROR_NOT_BUILT,     $name ) ) if $E;
        croak( sprintf( ERROR_CANT_OVERRIDE, $name ) ) if not defined $proto;
        $core = 1;
        $call = "CORE::$name";
    }

    if ( defined $proto ) {
        $real_proto = " ($proto)";
    }
    else {
        $real_proto = '';
        $proto      = '@';
    }

    my $true_name = $core ? $call : $sub;

    if ( my $subref = $Cached_fatalised_sub{$class}{$sub}{$void}{$lexical} ) {
        $class->_install_subs( $pkg, { $name => $subref } );
        return $sref;
    }

    $code = qq[
        sub$real_proto {
            local(\$", \$!) = (', ', 0);    # TODO - Why do we do this?
    ];

    $code .= "no warnings qw(exec);\n" if $call eq "CORE::exec";

    my @protos = fill_protos($proto);
    $code .=
      $class->_write_invocation( $core, $call, $name, $void, $lexical, $sub,
        $sref, @protos );
    $code .= "}\n";
    warn $code if $Debug;

    {
        no strict 'refs';

        my $E;

        {
            local $@;
            $code = eval("package $pkg; require Carp; $code");
            $E    = $@;
        }

        if ( not $code ) {
            croak("Internal error in autodie/Fatal processing $true_name: $E");

        }
    }

    my $leak_guard;

    if ($lexical) {

        $leak_guard = qq<
            package $pkg;

            sub$real_proto {

                # If we're inside a string eval, we can end up with a
                # whacky filename.  The following code allows autodie
                # to propagate correctly into string evals.

                my \$caller_level = 0;

                my \$caller;

                while ( (\$caller = (caller \$caller_level)[1]) =~ m{^\\(eval \\d+\\)\$} ) {

                    # If our filename is actually an eval, and we
                    # reach it, then go to our autodying code immediatately.

                    goto &\$code if (\$caller eq \$filename);
                    \$caller_level++;
                }

                # We're now out of the eval stack.

                # If we're called from the correct file, then use the
                # autodying code.
                goto &\$code if ((caller \$caller_level)[1] eq \$filename);

                # Oh bother, we've leaked into another file.  Call the
                # original code.  Note that \$sref may actually be a
                # reference to a Fatalised version of a core built-in.
                # That's okay, because Fatal *always* leaks between files.

                goto &\$sref if \$sref;
        >;

        foreach my $proto (@protos) {
            local $" = ", ";
            my ( $count, @args ) = @$proto;
            $leak_guard .= qq<
                if (\@_ == $count) {
                    return $call(@args);
                }
            >;
        }

        $leak_guard .=
qq< Carp::croak("Internal error in Fatal/autodie.  Leak-guard failure"); } >;

        my $E;
        {
            local $@;

            $leak_guard = eval $leak_guard;

            $E = $@;
        }

        die "Internal error in $class: Leak-guard installation failure: $E"
          if $E;
    }

    my $installed_sub = $leak_guard || $code;

    $class->_install_subs( $pkg, { $name => $installed_sub } );

    $Cached_fatalised_sub{$class}{$sub}{$void}{$lexical} = $installed_sub;

    $Is_fatalised_sub{$installed_sub} = $sref;

    return $sref;

}

sub exception_class { return "autodie::exception" }

{
    my %exception_class_for;
    my %class_loaded;

    sub throw {
        my ( $class, @args ) = @_;

        my $exception_class =
          $exception_class_for{$class} ||= $class->exception_class;

        if ( not $class_loaded{$exception_class} ) {
            if ( $exception_class =~ /[^\w:']/ ) {
                confess
"Bad exception class '$exception_class'.\nThe '$class->exception_class' method wants to use $exception_class\nfor exceptions, but it contains characters which are not word-characters or colons.";
            }

            my $E;

            {
                local $@;
                eval "require $exception_class";
                $E = $@;
            }

            confess
"Failed to load '$exception_class'.\nThis may be a typo in the '$class->exception_class' method,\nor the '$exception_class' module may not exist.\n\n $E"
              if $E;

            $class_loaded{$exception_class}++;

        }

        return $exception_class->new(@args);
    }
}

sub _autocroak {
    warn Carp::longmess(@_);
    exit(255);
}

package autodie::Scope::Guard;

sub new {
    my ( $class, $handler ) = @_;

    return bless $handler, $class;
}

sub DESTROY {
    my ($self) = @_;

    $self->();
}

1;

__END__

