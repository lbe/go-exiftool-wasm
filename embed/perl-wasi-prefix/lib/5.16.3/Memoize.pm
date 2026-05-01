
package Memoize;
$VERSION = '1.02';

sub SCALAR () { 0 }
sub LIST ()   { 1 }

use Carp;
use Exporter;
use vars qw($DEBUG);
use Config;
@ISA       = qw(Exporter);
@EXPORT    = qw(memoize);
@EXPORT_OK = qw(unmemoize flush_cache);
use strict;

my %memotable;
my %revmemotable;
my @CONTEXT_TAGS = qw(MERGE TIE MEMORY FAULT HASH);
my %IS_CACHE_TAG = map { ( $_ => 1 ) } @CONTEXT_TAGS;

my %scalar_only =
  map { ( $_ => 1 ) } qw(DB_File GDBM_File SDBM_File ODBM_File NDBM_File);

sub memoize {
    my $fn      = shift;
    my %options = @_;
    my $options = \%options;

    unless ( defined($fn)
        && ( ref $fn eq 'CODE' || ref $fn eq '' ) )
    {
        croak "Usage: memoize 'functionname'|coderef {OPTIONS}";
    }

    my $uppack = caller;
    my $cref;
    my $name = ( ref $fn ? undef : $fn );

    $cref = &_make_cref( $fn, $uppack );

    my $proto = prototype $cref;
    if   ( defined $proto ) { $proto = "($proto)" }
    else                    { $proto = "" }

    my $wrapper =
      $Config{usethreads}
      ? eval "sub $proto { &_memoizer(\$cref, \@_); }"
      : eval "sub $proto { unshift \@_, \$cref; goto &_memoizer; }";

    my $normalizer = $options{NORMALIZER};
    if ( defined $normalizer && !ref $normalizer ) {
        $normalizer = _make_cref( $normalizer, $uppack );
    }

    my $install_name;
    if ( defined $options->{INSTALL} ) {
        $install_name = $options->{INSTALL};
    }
    elsif ( !exists $options->{INSTALL} ) {
        $install_name = $name;
    }
    else {
    }

    if ( defined $install_name ) {
        $install_name = $uppack . '::' . $install_name
          unless $install_name =~ /::/;
        no strict;
        local ($^W) = 0;
        *{$install_name} = $wrapper;
    }

    $revmemotable{$wrapper} = "" . $cref;

    my %caches;
    for my $context (qw(SCALAR LIST)) {
        $options{"${context}_CACHE"} ||= '';

        my $cache_opt = $options{"${context}_CACHE"};
        my @cache_opt_args;
        if ( ref $cache_opt ) {
            @cache_opt_args = @$cache_opt;
            $cache_opt      = shift @cache_opt_args;
        }
        if ( $cache_opt eq 'FAULT' ) { $caches{$context} = undef;
        }
        elsif ( $cache_opt eq 'HASH' ) { my $cache = $cache_opt_args[0];
            my $package = ref( tied %$cache );
            if ( $context eq 'LIST' && $scalar_only{$package} ) {
                croak(
"You can't use $package for LIST_CACHE because it can only store scalars"
                );
            }
            $caches{$context} = $cache;
        }
        elsif ( $cache_opt eq '' || $IS_CACHE_TAG{$cache_opt} ) {
            $caches{$context} = {};
        }
        else {
            croak
"Unrecognized option to `${context}_CACHE': `$cache_opt' should be one of (@CONTEXT_TAGS); aborting";
        }
    }

    if ( $options{SCALAR_CACHE} eq 'MERGE' ) {
        $caches{SCALAR} = $caches{LIST};
    }
    elsif ( $options{LIST_CACHE} eq 'MERGE' ) {
        $caches{LIST} = $caches{SCALAR};
    }

    {
        my $context;
        foreach $context (qw(SCALAR LIST)) {
            _my_tie( $context, $caches{$context}, $options );
        }
    }

    $memotable{$cref} = {
        O        => $options, N => $normalizer,
        U        => $cref,
        MEMOIZED => $wrapper,
        PACKAGE  => $uppack,
        NAME     => $install_name,
        S        => $caches{SCALAR},
        L        => $caches{LIST},
    };

    $wrapper;
}

sub _my_tie {
    my ( $context, $hash, $options ) = @_;
    my $fullopt = $options->{"${context}_CACHE"};

    my $shortopt = ( ref $fullopt ) ? $fullopt->[0] : $fullopt;

    return unless defined $shortopt && $shortopt eq 'TIE';
    carp("TIE option to memoize() is deprecated; use HASH instead")
      if $^W;

    my @args = ref $fullopt ? @$fullopt : ();
    shift @args;
    my $module = shift @args;
    if ( $context eq 'LIST' && $scalar_only{$module} ) {
        croak(
"You can't use $module for LIST_CACHE because it can only store scalars"
        );
    }
    my $modulefile = $module . '.pm';
    $modulefile =~ s{::}{/}g;
    eval { require $modulefile };
    if ($@) {
        croak "Memoize: Couldn't load hash tie module `$module': $@; aborting";
    }
    my $rc = ( tie %$hash => $module, @args );
    unless ($rc) {
        croak "Memoize: Couldn't tie hash to `$module': $!; aborting";
    }
    1;
}

sub flush_cache {
    my $func = _make_cref( $_[0], scalar caller );
    my $info = $memotable{ $revmemotable{$func} };
    die "$func not memoized" unless defined $info;
    for my $context (qw(S L)) {
        my $cache = $info->{$context};
        if ( tied %$cache && !( tied %$cache )->can('CLEAR') ) {
            my $funcname =
              defined( $info->{NAME} )
              ? "function $info->{NAME}"
              : "anonymous function $func";
            my $context = { S => 'scalar', L => 'list' }->{$context};
            croak
"Tied cache hash for $context-context $funcname does not support flushing";
        }
        else {
            %$cache = ();
        }
    }
}

sub _memoizer {
    my $orig       = shift;
    my $info       = $memotable{$orig};
    my $normalizer = $info->{N};

    my $argstr;
    my $context = ( wantarray() ? LIST : SCALAR );

    if ( defined $normalizer ) {
        no strict;
        if ( $context == SCALAR ) {
            $argstr = &{$normalizer}(@_);
        }
        elsif ( $context == LIST ) {
            ($argstr) = &{$normalizer}(@_);
        }
        else {
            croak "Internal error \#41; context was neither LIST nor SCALAR\n";
        }
    }
    else { local $^W = 0;
        $argstr = join chr(28), @_;
    }

    if ( $context == SCALAR ) {
        my $cache = $info->{S};
        _crap_out( $info->{NAME}, 'scalar' ) unless $cache;
        if ( exists $cache->{$argstr} ) {
            return $cache->{$argstr};
        }
        else {
            my $val = &{ $info->{U} }(@_);
            if ( $info->{O}{SCALAR_CACHE} eq 'MERGE' ) {
                $cache->{$argstr} = [$val];
            }
            else {
                $cache->{$argstr} = $val;
            }
            $val;
        }
    }
    elsif ( $context == LIST ) {
        my $cache = $info->{L};
        _crap_out( $info->{NAME}, 'list' ) unless $cache;
        if ( exists $cache->{$argstr} ) {
            my $val = $cache->{$argstr};
            return ($val) if $info->{O}{LIST_CACHE} eq 'MERGE';

            return @$val;
        }
        else {
            my @q = &{ $info->{U} }(@_);
            $cache->{$argstr} = $info->{O}{LIST_CACHE} eq 'MERGE' ? $q[0] : \@q;
            @q;
        }
    }
    else {
        croak "Internal error \#42; context was neither LIST nor SCALAR\n";
    }
}

sub unmemoize {
    my $f      = shift;
    my $uppack = caller;
    my $cref   = _make_cref( $f, $uppack );

    unless ( exists $revmemotable{$cref} ) {
        croak
"Could not unmemoize function `$f', because it was not memoized to begin with";
    }

    my $tabent = $memotable{ $revmemotable{$cref} };
    unless ( defined $tabent ) {
        croak "Could not figure out how to unmemoize function `$f'";
    }
    my $name = $tabent->{NAME};
    if ( defined $name ) {
        no strict;
        local ($^W) = 0;
        *{$name} = $tabent->{U};
    }
    undef $memotable{ $revmemotable{$cref} };
    undef $revmemotable{$cref};

    $tabent->{U};
}

sub _make_cref {
    my $fn     = shift;
    my $uppack = shift;
    my $cref;
    my $name;

    if ( ref $fn eq 'CODE' ) {
        $cref = $fn;
    }
    elsif ( !ref $fn ) {
        if ( $fn =~ /::/ ) {
            $name = $fn;
        }
        else {
            $name = $uppack . '::' . $fn;
        }
        no strict;
        if ( defined $name and !defined(&$name) ) {
            croak "Cannot operate on nonexistent function `$fn'";
        }
        $cref = *{$name}{CODE};
    }
    else {
        my $parent = ( caller(1) )[3];
        croak
"Usage: argument 1 to `$parent' must be a function name or reference.\n";
    }
    $DEBUG and warn "${name}($fn) => $cref in _make_cref\n";
    $cref;
}

sub _crap_out {
    my ( $funcname, $context ) = @_;
    if ( defined $funcname ) {
        croak
          "Function `$funcname' called in forbidden $context context; faulting";
    }
    else {
        croak
          "Anonymous function called in forbidden $context context; faulting";
    }
}

1;

