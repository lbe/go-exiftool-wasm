package Params::Check;

use strict;

use Carp qw[carp croak];
use Locale::Maketext::Simple Style => 'gettext';

BEGIN {
    use Exporter ();
    use vars qw[ @ISA $VERSION @EXPORT_OK $VERBOSE $ALLOW_UNKNOWN
      $STRICT_TYPE $STRIP_LEADING_DASHES $NO_DUPLICATES
      $PRESERVE_CASE $ONLY_ALLOW_DEFINED $WARNINGS_FATAL
      $SANITY_CHECK_TEMPLATE $CALLER_DEPTH $_ERROR_STRING
    ];

    @ISA       = qw[ Exporter ];
    @EXPORT_OK = qw[check allow last_error];

    $VERSION               = '0.32';
    $VERBOSE               = $^W ? 1 : 0;
    $NO_DUPLICATES         = 0;
    $STRIP_LEADING_DASHES  = 0;
    $STRICT_TYPE           = 0;
    $ALLOW_UNKNOWN         = 0;
    $PRESERVE_CASE         = 0;
    $ONLY_ALLOW_DEFINED    = 0;
    $SANITY_CHECK_TEMPLATE = 1;
    $WARNINGS_FATAL        = 0;
    $CALLER_DEPTH          = 0;
}

my %known_keys = map { $_ => 1 }
  qw| required allow default strict_type no_override
  store defined |;


sub check {
    my ( $utmpl, $href, $verbose ) = @_;

    _clear_error();

    if ( !$utmpl or !$href ) {
        _store_error( loc('check() expects two arguments') );
        return unless $WARNINGS_FATAL;
        croak( __PACKAGE__->last_error );
    }

    $verbose ||= $VERBOSE || 0;

    my $args = _clean_up_args($href) or return;

    my $defs = _sanity_check_and_defaults( $utmpl, $args, $verbose )
      or return;

    my %utmpl = %$utmpl;
    my %args  = %$args;
    my %defs  = %$defs;

    my $wrong;

    my $warned;

    for my $key ( keys %args ) {

        unless ( $utmpl{$key} ) {

            if ($ALLOW_UNKNOWN) {
                $defs{$key} = $args{$key};

            }
            else {
                _store_error(
                    loc(
                        "Key '%1' is not a valid key for %2 provided by %3",
                        $key, _who_was_it(), _who_was_it(1)
                    ),
                    $verbose
                );
                $warned ||= 1;
            }
            next;
        }

        if ( $utmpl{$key}->{'no_override'} ) {
            _store_error(
                loc(
                    q[You are not allowed to override key '%1']
                      . q[for %2 from %3],
                    $key,
                    _who_was_it(),
                    _who_was_it(1)
                ),
                $verbose
            );
            $warned ||= 1;
            next;
        }

        my %tmpl = %{ $utmpl{$key} };

        if ( ( $tmpl{'defined'} || $ONLY_ALLOW_DEFINED )
            and not defined $args{$key} )
        {
            _store_error( loc( q|Key '%1' must be defined when passed|, $key ),
                $verbose );
            $wrong ||= 1;
            next;
        }

        if (    ( $tmpl{'strict_type'} || $STRICT_TYPE )
            and ( ref $args{$key} ne ref $tmpl{'default'} ) )
        {
            _store_error(
                loc(
                    q|Key '%1' needs to be of type '%2'|,
                    $key,
                    ref $tmpl{'default'} || 'SCALAR'
                ),
                $verbose
            );
            $wrong ||= 1;
            next;
        }

        if (
            exists $tmpl{'allow'} and not do {
                local $_ERROR_STRING;
                allow( $args{$key}, $tmpl{'allow'} );
            }
          )
        {
            _store_error(
                loc(
                    q|Key '%1' (%2) is of invalid type for '%3' |
                      . q|provided by %4|,
                    $key,
                    "$args{$key}",
                    _who_was_it(),
                    _who_was_it(1)
                ),
                $verbose
            );
            $wrong ||= 1;
            next;
        }

        $defs{$key} = $args{$key};

    }

    croak( __PACKAGE__->last_error )
      if ( $wrong || $warned ) && $WARNINGS_FATAL;

    return if $wrong;

    for my $key ( keys %defs ) {
        if ( my $ref = $utmpl{$key}->{'store'} ) {
            $$ref = $NO_DUPLICATES ? delete $defs{$key} : $defs{$key};
        }
    }

    return \%defs;
}


sub allow {

    if ( ref $_[1] eq 'Regexp' ) {
        local $^W;
        return if $_[0] !~ /$_[1]/;

    }
    elsif ( ref $_[1] eq 'CODE' ) {
        return unless $_[1]->( $_[0] );

    }
    elsif ( ref $_[1] eq 'ARRAY' ) {

        for ( @{ $_[1] } ) {
            return 1 if allow( $_[0], $_ );
        }

        return;

    }
    else {
        return unless _safe_eq( $_[0], $_[1] );
    }

    return 1;
}

sub _clean_up_args {
    return $_[0] if $PRESERVE_CASE and !$STRIP_LEADING_DASHES;

    my %args = %{ $_[0] };

    for my $key ( keys %args ) {
        my $org = $key;
        $key = lc $key unless $PRESERVE_CASE;
        $key =~ s/^-// if $STRIP_LEADING_DASHES;
        $args{$key} = delete $args{$org} if $key ne $org;
    }

    return \%args;
}

sub _sanity_check_and_defaults {
    my %utmpl   = %{ $_[0] };
    my %args    = %{ $_[1] };
    my $verbose = $_[2];

    my %defs;
    my $fail;
    for my $key ( keys %utmpl ) {

        if ( $utmpl{$key}->{'required'} and not exists $args{$key} ) {
            _store_error(
                loc(
                    q|Required option '%1' is not provided for %2 by %3|,
                    $key, _who_was_it(1), _who_was_it(2)
                ),
                $verbose
            );

            $fail++;
            next;
        }

        $defs{$key} = $utmpl{$key}->{'default'}
          if exists $utmpl{$key}->{'default'};

        if ($SANITY_CHECK_TEMPLATE) {
            map {
                _store_error(
                    loc(
                        q|Template type '%1' not supported [at key '%2']|,
                        $_, $key
                    ),
                    1, 1
                );
            } grep { not $known_keys{$_} } keys %{ $utmpl{$key} };

            if ( exists $utmpl{$key}->{'store'} ) {
                _store_error(
                    loc( q|Store variable for '%1' is not a reference!|, $key ),
                    1, 1
                ) unless ref $utmpl{$key}->{'store'};
            }
        }
    }

    return if $fail;

    return \%defs;
}

sub _safe_eq {
    return defined( $_[0] ) && defined( $_[1] )
      ? $_[0] eq $_[1]
      : defined( $_[0] ) eq defined( $_[1] );
}

sub _who_was_it {
    my $level = $_[0] || 0;

    return ( caller( 2 + $CALLER_DEPTH + $level ) )[3] || 'ANON';
}


{
    $_ERROR_STRING = '';

    sub _store_error {
        my ( $err, $verbose, $offset ) = @_[ 0 .. 2 ];
        $verbose ||= 0;
        $offset  ||= 0;
        my $level = 1 + $offset;

        local $Carp::CarpLevel = $level;

        carp $err if $verbose;

        $_ERROR_STRING .= $err . "\n";
    }

    sub _clear_error {
        $_ERROR_STRING = '';
    }

    sub last_error { $_ERROR_STRING }
}

1;


