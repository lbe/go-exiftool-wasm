package IO::Uncompress::Bunzip2;

use strict;
use warnings;
use bytes;

use IO::Compress::Base::Common 2.048 qw(:Status createSelfTiedObject);

use IO::Uncompress::Base 2.048;
use IO::Uncompress::Adapter::Bunzip2 2.048;

require Exporter;
our ( $VERSION, @ISA, @EXPORT_OK, %EXPORT_TAGS, $Bunzip2Error );

$VERSION      = '2.048';
$Bunzip2Error = '';

@ISA       = qw( Exporter IO::Uncompress::Base );
@EXPORT_OK = qw( $Bunzip2Error bunzip2 );
push @{ $EXPORT_TAGS{all} }, @EXPORT_OK;

sub new {
    my $class = shift;
    my $obj = createSelfTiedObject( $class, \$Bunzip2Error );

    $obj->_create( undef, 0, @_ );
}

sub bunzip2 {
    my $obj = createSelfTiedObject( undef, \$Bunzip2Error );
    return $obj->_inf(@_);
}

sub getExtraParams {
    my $self = shift;

    use IO::Compress::Base::Common 2.048 qw(:Parse);

    return (
        'Verbosity' => [ 1, 1, Parse_boolean, 0 ],
        'Small'     => [ 1, 1, Parse_boolean, 0 ],
    );
}

sub ckParams {
    my $self = shift;
    my $got  = shift;

    return 1;
}

sub mkUncomp {
    my $self = shift;
    my $got  = shift;

    my $magic = $self->ckMagic()
      or return 0;

    *$self->{Info} = $self->readHeader($magic)
      or return undef;

    my $Small     = $got->value('Small');
    my $Verbosity = $got->value('Verbosity');

    my ( $obj, $errstr, $errno ) =
      IO::Uncompress::Adapter::Bunzip2::mkUncompObject( $Small, $Verbosity );

    return $self->saveErrorString( undef, $errstr, $errno )
      if !defined $obj;

    *$self->{Uncomp} = $obj;

    return 1;

}

sub ckMagic {
    my $self = shift;

    my $magic;
    $self->smartReadExact( \$magic, 4 );

    *$self->{HeaderPending} = $magic;

    return $self->HeaderError( "Header size is " . 4 . " bytes" )
      if length $magic != 4;

    return $self->HeaderError("Bad Magic.")
      if !isBzip2Magic($magic);

    *$self->{Type} = 'bzip2';
    return $magic;
}

sub readHeader {
    my $self  = shift;
    my $magic = shift;

    $self->pushBack($magic);
    *$self->{HeaderPending} = '';

    return {
        'Type'              => 'bzip2',
        'FingerprintLength' => 4,
        'HeaderLength'      => 4,
        'TrailerLength'     => 0,
        'Header'            => '$magic'
    };

}

sub chkTrailer {
    return STATUS_OK;
}

sub isBzip2Magic {
    my $buffer = shift;
    return $buffer =~ /^BZh\d$/;
}

1;

__END__


