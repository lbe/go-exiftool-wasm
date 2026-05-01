package CPANPLUS::Module::Checksums;

use strict;
use vars qw[@ISA];

use CPANPLUS::Error;
use CPANPLUS::Internals::Constants;

use FileHandle;

use Locale::Maketext::Simple Class => 'CPANPLUS', Style => 'gettext';
use Params::Check qw[check];
use Module::Load::Conditional qw[can_load];

$Params::Check::VERBOSE = 1;

@ISA = qw[ CPANPLUS::Module::Signature ];


sub checksums {
    my $mod = shift or return;

    my $file = $mod->_get_checksums_file(@_);

    return $mod->status->checksums($file) if $file;

    return;
}

sub _validate_checksum {
    my $self = shift;
    my $conf = $self->parent->configure_object;
    my %hash = @_;

    my $verbose;
    my $tmpl = {
        verbose => {
            default => $conf->get_conf('verbose'),
            store   => \$verbose
        },
    };

    check( $tmpl, \%hash ) or return;

    return $self->status->checksum_ok(1)
      unless can_load( modules => { 'Digest::SHA' => '0.0' } );

    my $file = $self->_get_checksums_file( verbose => $verbose )
      or ( error( loc( q[Could not fetch '%1' file], CHECKSUMS ) ), return );

    $self->_check_signature_for_checksum_file( file => $file )
      or ( error( loc( q[Could not verify '%1' file], CHECKSUMS ) ), return );

    my $href = $self->_parse_checksums_file( file => $file )
      or ( error( loc( q[Could not parse '%1' file], CHECKSUMS ) ), return );

    my $size = $href->{ $self->package }->{'size'};

    if ( defined $size ) {
        if ( not( -s $self->status->fetch == $size ) ) {
            error(
                loc(
                    "Archive size does not match for '%1': "
                      . "size is '%2' but should be '%3'",
                    $self->package, -s $self->status->fetch, $size
                )
            );
            return $self->status->checksum_ok(0);
        }
    }
    else {
        msg( loc( "Archive size is not known for '%1'", $self->package ),
            $verbose );
    }

    my $sha = $href->{ $self->package }->{'sha256'};

    unless ( defined $sha ) {
        msg( loc( "No 'sha256' checksum known for '%1'", $self->package ),
            $verbose );

        return $self->status->checksum_ok(1);
    }

    $self->status->checksum_value($sha);

    my $fh = FileHandle->new( $self->status->fetch ) or return;
    binmode $fh;

    my $ctx = Digest::SHA->new(256);
    $ctx->addfile($fh);

    my $hexdigest = $ctx->hexdigest;
    my $flag = $hexdigest eq $sha;
    $flag
      ? msg( loc( "Checksum matches for '%1'", $self->package ), $verbose )
      : error(
        loc(
            "Checksum does not match for '%1': "
              . "SHA256 is '%2' but should be '%3'",
            $self->package, $hexdigest, $sha
        ),
        $verbose
      );

    return $self->status->checksum_ok(1) if $flag;
    return $self->status->checksum_ok(0);
}

sub _get_checksums_file {
    my $self = shift;
    my %hash = @_;

    my $clone = $self->clone;
    $clone->package(CHECKSUMS);

    my $file = $clone->fetch( ttl => 3600, %hash ) or return;

    return $file;
}

sub _parse_checksums_file {
    my $self = shift;
    my %hash = @_;

    my $file;
    my $tmpl =
      { file => { required => 1, allow => FILE_READABLE, store => \$file }, };
    my $args = check( $tmpl, \%hash );

    my $fh = OPEN_FILE->($file) or return;

    my $signed;
    while ( local $_ = <$fh> ) {
        last if /^\$cksum = \{\s*$/;
        my $header = PGP_HEADER;
        $signed = 1 if /^${header}\s*$/;
    }

    my $dist;
    my $cksum = {};
    while ( local $_ = <$fh> ) {

        if (/^\s*'([^']+)' => \{\s*$/) {
            $dist = $1;

        }
        elsif ( /^\s*'([^']+)' => '?([^'\n]+)'?,?\s*$/ and defined $dist ) {
            $cksum->{$dist}{$1} = $2;

        }
        elsif (/^\s*}[,;]?\s*$/) {
            undef $dist;

        }
        elsif (/^__END__\s*$/) {
            last;

        }
        else {
            error( loc( "Malformed %1 line: %2", CHECKSUMS, $_ ) );
        }
    }

    return $cksum;
}

sub _check_signature_for_checksum_file {
    my $self = shift;

    my $conf = $self->parent->configure_object;
    my %hash = @_;

    return 1 unless $conf->get_conf('signature');

    my ( $force, $file, $verbose );
    my $tmpl = {
        file => { required => 1, allow => FILE_READABLE, store => \$file },
        force => { default => $conf->get_conf('force'), store => \$force },
        verbose =>
          { default => $conf->get_conf('verbose'), store => \$verbose },
    };

    my $args = check( $tmpl, \%hash ) or return;

    my $fh = OPEN_FILE->($file) or return;

    my $signed;
    while ( local $_ = <$fh> ) {
        my $header = PGP_HEADER;
        $signed = 1 if /^$header$/;
    }

    if ( !$signed ) {
        msg( loc( "No signature found in %1 file '%2'", CHECKSUMS, $file ),
            $verbose );

        return 1 unless $force;

        error(
            loc( "%1 file '%2' is not signed -- aborting", CHECKSUMS, $file ) );
        return;

    }

    if ( can_load( modules => { 'Module::Signature' => '0.06' } ) ) {
    }

    return 1;
}

1;
