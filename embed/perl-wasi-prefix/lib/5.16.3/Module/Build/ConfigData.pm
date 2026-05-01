package Module::Build::ConfigData;
use strict;
my $arrayref = eval do { local $/; <DATA> }
  or die "Couldn't load ConfigData data: $@";
close DATA;
my ( $config, $features, $auto_features ) = @$arrayref;

sub config { $config->{ $_[1] } }

sub set_config  { $config->{ $_[1] }   = $_[2] }
sub set_feature { $features->{ $_[1] } = 0 + !!$_[2] }

sub auto_feature_names { grep !exists $features->{$_}, keys %$auto_features }

sub feature_names {
    my @features = ( keys %$features, auto_feature_names() );
    @features;
}

sub config_names { keys %$config }

sub write {
    my $me = __FILE__;
    require IO::File;

    require Data::Dumper;

    my $mode_orig = ( stat $me )[2] & 07777;
    chmod( $mode_orig | 0222, $me );
    my $fh = IO::File->new( $me, 'r+' ) or die "Can't rewrite $me: $!";
    seek( $fh, 0, 0 );
    while (<$fh>) {
        last if /^__DATA__$/;
    }
    die "Couldn't find __DATA__ token in $me" if eof($fh);

    seek( $fh, tell($fh), 0 );
    my $data = [ $config, $features, $auto_features ];
    $fh->print( 'do{ my '
          . Data::Dumper->new( [$data], ['x'] )->Purity(1)->Dump()
          . '$x; }' );
    truncate( $fh, tell($fh) );
    $fh->close;

    chmod( $mode_orig, $me )
      or warn "Couldn't restore permissions on $me: $!";
}

sub feature {
    my ( $package, $key ) = @_;
    return $features->{$key} if exists $features->{$key};

    my $info = $auto_features->{$key} or return 0;

    my %info = %$info;

    require Module::Build;
    while ( my ( $type, $prereqs ) = each %info ) {
        next if $type eq 'description' || $type eq 'recommends';

        my %p = %$prereqs;
        while ( my ( $modname, $spec ) = each %p ) {
            my $status =
              Module::Build->check_installed_status( $modname, $spec );
            if ( ( !$status->{ok} ) xor( $type =~ /conflicts$/ ) ) { return 0; }
            if ( !eval "require $modname; 1" ) { return 0; }
        }
    }
    return 1;
}


__DATA__
do{ my $x = [
       {},
       {},
       {
         'license_creation' => {
                                 'requires' => {
                                                 'Software::License' => 0
                                               },
                                 'description' => 'Create licenses automatically in distributions'
                               },
         'inc_bundling_support' => {
                                     'requires' => {
                                                     'ExtUtils::Installed' => '1.999',
                                                     'ExtUtils::Install' => '1.54'
                                                   },
                                     'description' => 'Bundle Module::Build in inc/'
                                   },
         'manpage_support' => {
                                'requires' => {
                                                'Pod::Man' => 0
                                              },
                                'description' => 'Create Unix man pages'
                              },
         'PPM_support' => {
                            'requires' => {
                                            'IO::File' => '1.13'
                                          },
                            'description' => 'Generate PPM files for distributions'
                          },
         'dist_authoring' => {
                               'requires' => {
                                               'Archive::Tar' => '1.09'
                                             },
                               'recommends' => {
                                                 'Module::Signature' => '0.21',
                                                 'Pod::Readme' => '0.04'
                                               },
                               'description' => 'Create new distributions'
                             },
         'HTML_support' => {
                             'requires' => {
                                             'Pod::Html' => 0
                                           },
                             'description' => 'Create HTML documentation'
                           }
       }
     ];
$x; }
