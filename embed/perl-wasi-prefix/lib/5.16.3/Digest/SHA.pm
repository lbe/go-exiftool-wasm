package Digest::SHA;

require 5.003000;

use strict;
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK);
use Fcntl;
use integer;

$VERSION = '5.71';

require Exporter;
require DynaLoader;
@ISA       = qw(Exporter DynaLoader);
@EXPORT_OK = qw(
  hmac_sha1	hmac_sha1_base64	hmac_sha1_hex
  hmac_sha224	hmac_sha224_base64	hmac_sha224_hex
  hmac_sha256	hmac_sha256_base64	hmac_sha256_hex
  hmac_sha384	hmac_sha384_base64	hmac_sha384_hex
  hmac_sha512	hmac_sha512_base64	hmac_sha512_hex
  hmac_sha512224	hmac_sha512224_base64	hmac_sha512224_hex
  hmac_sha512256	hmac_sha512256_base64	hmac_sha512256_hex
  sha1		sha1_base64		sha1_hex
  sha224		sha224_base64		sha224_hex
  sha256		sha256_base64		sha256_hex
  sha384		sha384_base64		sha384_hex
  sha512		sha512_base64		sha512_hex
  sha512224	sha512224_base64	sha512224_hex
  sha512256	sha512256_base64	sha512256_hex);

eval {
    require Digest::base;
    push( @ISA, 'Digest::base' );
};

*addfile   = \&Addfile;
*hexdigest = \&Hexdigest;
*b64digest = \&B64digest;

sub new {
    my ( $class, $alg ) = @_;
    $alg =~ s/\D+//g if defined $alg;
    if ( ref($class) )
    { unless ( defined($alg) && ( $alg != $class->algorithm ) )
        {
            sharewind($$class);
            return ($class);
        }
        shaclose($$class) if $$class;
        $$class = shaopen($alg) || return;
        return ($class);
    }
    $alg = 1 unless defined $alg;
    my $state = shaopen($alg) || return;
    my $self = \$state;
    bless( $self, $class );
    return ($self);
}

sub DESTROY {
    my $self = shift;
    shaclose($$self) if $$self;
}

sub clone {
    my $self  = shift;
    my $state = shadup($$self) || return;
    my $copy  = \$state;
    bless( $copy, ref($self) );
    return ($copy);
}

*reset = \&new;

sub add_bits {
    my ( $self, $data, $nbits ) = @_;
    unless ( defined $nbits ) {
        $nbits = length($data);
        $data = pack( "B*", $data );
    }
    $nbits = length($data) * 8 if $nbits > length($data) * 8;
    shawrite( $data, $nbits, $$self );
    return ($self);
}

sub _bail {
    my $msg = shift;

    $msg .= ": $!";
    require Carp;
    Carp::croak($msg);
}

sub _addfile { my ( $self, $handle ) = @_;

    my $n;
    my $buf = "";

    while ( ( $n = read( $handle, $buf, 4096 ) ) ) {
        $self->add($buf);
    }
    _bail("Read failed") unless defined $n;

    $self;
}

sub Addfile {
    my ( $self, $file, $mode ) = @_;

    return ( _addfile( $self, $file ) ) unless ref( \$file ) eq 'SCALAR';

    $mode = defined($mode) ? $mode : "";
    my ( $binary, $portable, $BITS ) = map { $_ eq $mode } ( "b", "p", "0" );

    local *FH;
    $file eq '-' and open( FH, '< -' )
      or sysopen( FH, $file, O_RDONLY )
      or _bail('Open failed');

    if ($BITS) {
        my ( $n, $buf ) = ( 0, "" );
        while ( ( $n = read( FH, $buf, 4096 ) ) ) {
            $buf =~ s/[^01]//g;
            $self->add_bits($buf);
        }
        _bail("Read failed") unless defined $n;
        close(FH);
        return ($self);
    }

    binmode(FH) if $binary || $portable;
    unless ( $portable && -T $file ) {
        $self->_addfile(*FH);
        close(FH);
        return ($self);
    }

    my ( $n1, $n2 );
    my ( $buf1, $buf2 ) = ( "", "" );

    while ( ( $n1 = read( FH, $buf1, 4096 ) ) ) {
        while ( substr( $buf1, -1 ) eq "\015" ) {
            $n2 = read( FH, $buf2, 4096 );
            _bail("Read failed") unless defined $n2;
            last unless $n2;
            $buf1 .= $buf2;
        }
        $buf1 =~ s/\015?\015\012/\012/g;
        $buf1 =~ s/\015/\012/g;
        $self->add($buf1);
    }
    _bail("Read failed") unless defined $n1;
    close(FH);

    $self;
}

sub dump {
    my $self = shift;
    my $file = shift || "";

    shadump( $file, $$self ) || return;
    return ($self);
}

sub load {
    my $class = shift;
    my $file = shift || "";
    if ( ref($class) ) { shaclose($$class) if $$class;
        $$class = shaload($file) || return;
        return ($class);
    }
    my $state = shaload($file) || return;
    my $self = \$state;
    bless( $self, $class );
    return ($self);
}

Digest::SHA->bootstrap($VERSION);

1;
__END__

