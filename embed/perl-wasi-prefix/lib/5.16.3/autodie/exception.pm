package autodie::exception;
use 5.008;
use strict;
use warnings;
use Carp qw(croak);

our $DEBUG = 0;

use overload q{""} => "stringify";

use if ( $] >= 5.010 ), overload => '~~' => "matches";

our $VERSION = '2.10';

my $PACKAGE = __PACKAGE__;



sub args { return $_[0]->{$PACKAGE}{args}; }


sub function { return $_[0]->{$PACKAGE}{function}; }


sub file { return $_[0]->{$PACKAGE}{file}; }


sub package { return $_[0]->{$PACKAGE}{package}; }


sub caller { return $_[0]->{$PACKAGE}{caller}; }


sub line { return $_[0]->{$PACKAGE}{line}; }


sub context { return $_[0]->{$PACKAGE}{context} }


sub return { return $_[0]->{$PACKAGE}{return} }


sub errno { return $_[0]->{$PACKAGE}{errno}; }


sub eval_error { return $_[0]->{$PACKAGE}{eval_error}; }


{
    my (%cache);

    sub matches {
        my ( $this, $that ) = @_;

        croak "UNIMPLEMENTED" if ref $that;

        my $sub = $this->function;

        if ($DEBUG) {
            my $sub2 = $this->function;
            warn "Smart-matching $that against $sub / $sub2\n";
        }

        return 1 if $that eq $sub;
        return 1 if $that !~ /:/ and "CORE::$that" eq $sub;
        return 0 if $that !~ /^:/;

        require Fatal;

        if ( exists $cache{$sub}{$that} ) {
            return $cache{$sub}{$that};
        }

        return $cache{$sub}{$that} =
          grep { $_ eq $sub } @{ $this->_expand_tag($that) };
    }
}

sub _expand_tag {
    my ( $this, @args ) = @_;

    return Fatal->_expand_tag(@args);
}


my %formatter_of = (
    'CORE::close'   => \&_format_close,
    'CORE::open'    => \&_format_open,
    'CORE::dbmopen' => \&_format_dbmopen,
    'CORE::flock'   => \&_format_flock,
);

sub _format_flock {
    my ($this) = @_;

    require Fcntl;

    my $filehandle = $this->args->[0];
    my $raw_mode   = $this->args->[1];

    my $mode_type;
    my $lock_unlock;

    if ( $raw_mode & Fcntl::LOCK_EX() ) {
        $lock_unlock = "lock";
        $mode_type   = "for exclusive access";
    }
    elsif ( $raw_mode & Fcntl::LOCK_SH() ) {
        $lock_unlock = "lock";
        $mode_type   = "for shared access";
    }
    elsif ( $raw_mode & Fcntl::LOCK_UN() ) {
        $lock_unlock = "unlock";
        $mode_type   = "";
    }
    else {
        $lock_unlock = "lock";
        $mode_type   = "with mode $raw_mode";
    }

    my $cooked_filehandle;

    if ( $filehandle and not ref $filehandle ) {

        $cooked_filehandle = " $filehandle";
    }
    else {

        $cooked_filehandle = '';

    }

    local $! = $this->errno;

    return "Can't $lock_unlock filehandle$cooked_filehandle $mode_type: $!";

}

sub _format_dbmopen {
    my ($this) = @_;
    my @args = @{ $this->args };

    my $mode = $args[-1];
    my $file = $args[-2];

    if ( $mode =~ /^[^\D0]\d+$/ ) {
        $mode = sprintf( "0%lo", $mode );
    }

    local $! = $this->errno;

    return "Can't dbmopen(%hash, '$file', $mode): '$!'";
}

sub _format_close {
    my ($this) = @_;
    my $close_arg = $this->args->[0];

    local $! = $this->errno;

    if ( $close_arg and not ref $close_arg ) {
        return "Can't close filehandle '$close_arg': '$!'";
    }

    return "Can't close($close_arg) filehandle: '$!'";

}

use constant _FORMAT_OPEN => "Can't open '%s' for %s: '%s'";

sub _format_open_with_mode {
    my ( $this, $mode, $file, $error ) = @_;

    my $wordy_mode;

    if    ( $mode eq '<' )  { $wordy_mode = 'reading'; }
    elsif ( $mode eq '>' )  { $wordy_mode = 'writing'; }
    elsif ( $mode eq '>>' ) { $wordy_mode = 'appending'; }

    return sprintf _FORMAT_OPEN, $file, $wordy_mode, $error if $wordy_mode;

    Carp::confess(
"Internal autodie::exception error: Don't know how to format mode '$mode'."
    );

}

sub _format_open {
    my ($this) = @_;

    my @open_args = @{ $this->args };

    if ( @open_args <= 1 or @open_args >= 4 ) {
        return $this->format_default;
    }

    if ( @open_args == 2 ) {
        my ( $fh, $file ) = @open_args;

        if ( ref($fh) eq "GLOB" ) {
            $fh = '$fh';
        }

        my ($mode) = $file =~ m{
            ^\s*                # Spaces before mode
            (
                (?>             # Non-backtracking subexp.
                    <           # Reading
                    |>>?        # Writing/appending
                )
            )
            [^&]                # Not an ampersand (which means a dup)
        }x;

        if ( not $mode ) {

            if ( $file =~ m{^\s*\w+\s*$} ) {
                $mode = '<';
            }
            else {
                return $this->format_default;
            }
        }

        local $! = $this->errno;

        return $this->_format_open_with_mode( $mode, $file, $! );
    }

    my $file = $open_args[2];

    local $! = $this->errno;

    my $mode = $open_args[1];

    local $@;

    my $msg = eval { $this->_format_open_with_mode( $mode, $file, $! ); };

    return $msg if $msg;

    return "Can't open '$file' with mode '$open_args[1]': '$!'";
}


sub register {
    my ( $class, $symbol, $handler ) = @_;

    croak "Incorrect call to autodie::register" if @_ != 3;

    $formatter_of{$symbol} = $handler;

}


sub add_file_and_line {
    my ($this) = @_;

    return sprintf( " at %s line %d\n", $this->file, $this->line );
}


sub stringify {
    my ($this) = @_;

    my $call = $this->function;

    if ($DEBUG) {
        my $dying_pkg = $this->package;
        my $sub       = $this->function;
        my $caller    = $this->caller;
        warn "Stringifing exception for $dying_pkg :: $sub / $caller / $call\n";
    }

    if ( my $sub = $formatter_of{$call} ) {
        return $sub->($this) . $this->add_file_and_line;
    }

    return $this->format_default . $this->add_file_and_line;

}


sub format_default {
    my ($this) = @_;

    my $call = $this->function;

    local $! = $this->errno;

    $call =~ s/.*:://;

    my @args = @{ $this->args() };

    foreach my $arg (@args) {
        if ( not defined($arg) ) { $arg = 'undef' }
        elsif ( ref($arg) eq "GLOB" ) { $arg = '$fh' }
        else                          { $arg = qq{'$arg'} }
    }

    return "Can't $call(" . join( q{, }, @args ) . "): $!";

}


sub new {
    my ( $class, @args ) = @_;

    my $this = {};

    bless( $this, $class );

    $this->_init(@args);

    return $this;
}

sub _init {

    my ( $this, %args ) = @_;

    my $original_errno = $!;

    our $init_called = 1;

    my $class = ref $this;

    my ( $package, $file, $line, $sub );

    my $depth = 0;

    while (1) {
        $depth++;

        ( $package, $file, $line, $sub ) = CORE::caller($depth);

        next if $package->isa('Fatal');
        next if $package->isa($class);
        next if $package->isa(__PACKAGE__);
        next if $file =~ /^\(eval\s\d+\)$/;

        last;

    }

    my $first_guess_subroutine = $sub;

    while ( defined $sub and $sub =~ /^\(eval\)$|::__ANON__$/ ) {
        $depth++;

        $sub = ( CORE::caller($depth) )[3];
    }

    if ( not defined $sub ) {
        $sub = $first_guess_subroutine;
    }

    $this->{$PACKAGE}{package} = $package;
    $this->{$PACKAGE}{file}    = $file;
    $this->{$PACKAGE}{line}    = $line;
    $this->{$PACKAGE}{caller}  = $sub;
    $this->{$PACKAGE}{package} = $package;

    $this->{$PACKAGE}{errno} = $args{errno} || 0;

    $this->{$PACKAGE}{context}    = $args{context};
    $this->{$PACKAGE}{return}     = $args{return};
    $this->{$PACKAGE}{eval_error} = $args{eval_error};

    $this->{$PACKAGE}{args} = $args{args} || [];
    $this->{$PACKAGE}{function} = $args{function}
      or croak("$class->new() called without function arg");

    return $this;

}

1;

__END__

