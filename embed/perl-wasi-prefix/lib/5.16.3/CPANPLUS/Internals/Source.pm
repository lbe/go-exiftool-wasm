package CPANPLUS::Internals::Source;

use strict;

use CPANPLUS::Error;
use CPANPLUS::Module;
use CPANPLUS::Module::Fake;
use CPANPLUS::Module::Author;
use CPANPLUS::Internals::Constants;

use File::Fetch;
use Archive::Extract;

use IPC::Cmd qw[can_run];
use File::Temp qw[tempdir];
use File::Basename qw[dirname];
use Params::Check qw[check];
use Module::Load::Conditional qw[can_load];
use Locale::Maketext::Simple Class => 'CPANPLUS', Style => 'gettext';

$Params::Check::VERBOSE = 1;

{
    for my $sub (
        qw[_init_trees _finalize_trees
        _standard_trees_completed _custom_trees_completed
        _add_module_object _add_author_object _save_state
        ]
      )
    {
        no strict 'refs';
        *$sub = sub {
            my $self = shift;
            my $class = ref $self || $self;

            require Carp;
            Carp::croak(
                loc( "Class %1 must implement method '%2'", $class, $sub ) );
          }
    }
}

{
    my $recurse;

    sub _module_tree {
        my $self = $_[0];

        unless ( $self->_mtree or $recurse++ > 0 ) {
            my $uptodate = $self->_check_trees( @_[ 1 .. $#_ ] );
            $self->_build_trees( uptodate => $uptodate );
        }

        $recurse--;
        return $self->_mtree;
    }

    sub _author_tree {
        my $self = $_[0];

        unless ( $self->_atree or $recurse++ > 0 ) {
            my $uptodate = $self->_check_trees( @_[ 1 .. $#_ ] );
            $self->_build_trees( uptodate => $uptodate );
        }

        $recurse--;
        return $self->_atree;
    }

}



sub _build_trees {
    my ( $self, %hash ) = @_;
    my $conf = $self->configure_object;

    my ( $path, $uptodate, $use_stored, $verbose );
    my $tmpl = {
        path => { default => $conf->get_conf('base'), store => \$path },
        verbose =>
          { default => $conf->get_conf('verbose'), store => \$verbose },
        uptodate   => { required => 1, store => \$uptodate },
        use_stored => { default  => 1, store => \$use_stored },
    };

    my $args = check( $tmpl, \%hash ) or return;

    $self->_init_trees(
        path       => $path,
        uptodate   => $uptodate,
        verbose    => $verbose,
        use_stored => $use_stored,
      )
      or do {
        error( loc("Could not initialize trees") );
        return;
      };

    return unless $self->_mtree && $self->_atree;

    if ( not $self->_standard_trees_completed ) {

        $self->__create_author_tree(
            uptodate => $uptodate,
            path     => $path,
            verbose  => $verbose,
        ) or return;

        $self->_create_mod_tree(
            uptodate => $uptodate,
            path     => $path,
            verbose  => $verbose,
        ) or return;
    }

    if ( not $self->_custom_trees_completed ) {

        if ( $conf->get_conf('enable_custom_sources') ) {
            $self->__update_custom_module_sources( verbose => $verbose )
              or error( loc("Could not update custom module sources") );
        }

        if ( $conf->get_conf('enable_custom_sources') ) {
            $self->__create_custom_module_entries( verbose => $verbose )
              or error( loc("Could not create custom module entries") );
        }
    }

    $self->_finalize_trees(
        path       => $path,
        uptodate   => $uptodate,
        verbose    => $verbose,
        use_stored => $use_stored,
      )
      or do {
        error( loc("Could not finalize trees") );
        return;
      };

    return 1;
}


sub _check_trees {
    my ( $self, %hash ) = @_;
    my $conf = $self->configure_object;

    my $update_source;
    my $verbose;
    my $path;

    my $tmpl = {
        path => {
            default => $conf->get_conf('base'),
            store   => \$path
        },
        verbose => {
            default => $conf->get_conf('verbose'),
            store   => \$verbose
        },
        update_source => { default => 0, store => \$update_source },
    };

    my $args = check( $tmpl, \%hash ) or return;

    return 1 if $conf->get_conf('no_update') && !$update_source;

    msg( loc("Checking if source files are up to date"), $verbose );

    my $uptodate = 1;

    for my $name (qw[auth dslip mod]) {
        for my $file ( $conf->_get_source($name) ) {
            $self->__check_uptodate(
                file          => File::Spec->catfile( $path, $file ),
                name          => $name,
                update_source => $update_source,
                verbose       => $verbose,
            ) or $uptodate = 0;
        }
    }

    $self->__update_custom_module_sources( verbose => $verbose )
      if $conf->get_conf('enable_custom_sources')
      and ( $update_source or !$uptodate );

    return $uptodate;
}


sub __check_uptodate {
    my $self = shift;
    my %hash = @_;
    my $conf = $self->configure_object;

    my $tmpl = {
        file          => { required => 1 },
        name          => { required => 1 },
        update_source => { default  => 0 },
        verbose       => { default  => $conf->get_conf('verbose') },
    };

    my $args = check( $tmpl, \%hash ) or return;

    my $flag;
    unless ( -e $args->{'file'}
        && ( ( stat $args->{'file'} )[9] + $conf->_get_source('update') ) >
        time )
    {
        $flag = 1;
    }

    if ( $flag or $args->{'update_source'} ) {

        if ( $self->_update_source( name => $args->{'name'} ) ) {
            return 0;
            ;
        }
        else {
            msg(
                loc(
"Unable to update source, attempting to get away with using old source file!"
                ),
                $args->{verbose}
            );
            return 1;
        }

    }
    else {
        return 1;
    }
}


sub _update_source {
    my $self = shift;
    my %hash = @_;
    my $conf = $self->configure_object;

    my $verbose;
    my $tmpl = {
        name => { required => 1 },
        path => { default  => $conf->get_conf('base') },
        verbose =>
          { default => $conf->get_conf('verbose'), store => \$verbose },
    };

    my $args = check( $tmpl, \%hash ) or return;

    my $path = $args->{path};
    { my ( $dir, $file ) =
          $conf->_get_mirror( $args->{'name'} ) =~ m|(.+/)(.+)$|sg;

        msg( loc( "Updating source file '%1'", $file ), $verbose );

        my $fake = CPANPLUS::Module::Fake->new(
            module  => $args->{'name'},
            path    => $dir,
            package => $file,
            _id     => $self->_id,
        );

        my $rv = $self->_fetch(
            module   => $fake,
            fetchdir => $path,
            force    => 1,
        );

        unless ($rv) {
            error( loc( "Couldn't fetch '%1'", $file ) );
            return;
        }

        $self->_update_timestamp( file => File::Spec->catfile( $path, $file ) );
    }

    return 1;
}


sub __create_author_tree {
    my $self = shift;
    my %hash = @_;
    my $conf = $self->configure_object;

    my $tmpl = {
        path     => { default => $conf->get_conf('base') },
        verbose  => { default => $conf->get_conf('verbose') },
        uptodate => { default => 0 },
    };

    my $args = check( $tmpl, \%hash ) or return;

    my $file = File::Spec->catfile( $args->{path}, $conf->_get_source('auth') );

    msg( loc("Rebuilding author tree, this might take a while"),
        $args->{verbose} );

    my $ae = Archive::Extract->new( archive => $file ) or return;
    my $out = STRIP_GZ_SUFFIX->($file);

    {
        local $Archive::Extract::PREFER_BIN = $conf->get_conf('prefer_bin');
        $ae->extract( to => $out ) or return;
    }

    my $cont = $self->_get_file_contents( file => $out ) or return;

    unlink $out;

    my ( $tot, $prce, $prc, $idx );

    $args->{verbose}
      and local $| = 1,
      $tot = scalar( split /\n/, $cont ),
      ( $prce, $prc, $idx ) = ( int $tot / 25, 0, 0 );

    $args->{verbose}
      and print "\t0%";

    for ( split /\n/, $cont ) {
        my ( $id, $name, $email ) = m/^alias \s+
                                    (\S+) \s+
                                    "\s* ([^\"\<]+?) \s* <(.+)> \s*"
                                /x;

        $self->_add_author_object(
            author => $name, email => $email, cpanid => $id, )
          or error( loc( "Could not add author '%1'", $name ) );

        $args->{verbose}
          and (
            $idx++,

            ( $idx == $prce and ( $prc += 4, $idx = 0, print "." ) ),

            ( ( $prc % 10 ) or $idx or print $prc, '%' )
          );

    }

    $args->{verbose}
      and print "\n";

    return $self->_atree;

}


sub _create_mod_tree {
    my $self = shift;
    my %hash = @_;
    my $conf = $self->configure_object;

    my $tmpl = {
        path     => { default => $conf->get_conf('base') },
        verbose  => { default => $conf->get_conf('verbose') },
        uptodate => { default => 0 },
    };

    my $args = check( $tmpl, \%hash ) or return undef;
    my $file = File::Spec->catfile( $args->{path}, $conf->_get_source('mod') );

    msg( loc("Rebuilding module tree, this might take a while"),
        $args->{verbose} );

    my $dslip_tree = $self->__create_dslip_tree(%$args);

    my $ae = Archive::Extract->new( archive => $file ) or return;
    my $out = STRIP_GZ_SUFFIX->($file);

    {
        local $Archive::Extract::PREFER_BIN = $conf->get_conf('prefer_bin');
        $ae->extract( to => $out ) or return;
    }

    my $content = $self->_get_file_contents( file => $out ) or return;
    my $lines = $content =~ tr/\n/\n/;

    unlink $out;

    my ( $past_header, $count, $tot, $prce, $prc, $idx );

    $args->{verbose}
      and local $| = 1,
      $tot = scalar( split /\n/, $content ),
      ( $prce, $prc, $idx ) = ( int $tot / 25, 0, 0 );

    $args->{verbose}
      and print "\t0%";

    for ( split /\n/, $content ) {
        if (m|^\s*$|) {
            unless ($count) {
                error( loc( "Could not determine line count from %1", $file ) );
                return;
            }
            $past_header = 1;
        }

        unless ($past_header) {

            $count = $1 if /^Line-Count:\s+(\d+)/;
            if ($count) {
                if ( $lines < $count ) {
                    error(
                        loc(
                            "Expected to read at least %1 lines, but %2 "
                              . "contains only %3 lines!",
                            $count, $file, $lines
                        )
                    );
                    return;
                }
            }
            next;
        }

        next unless /\S/;
        chomp;

        my @data = split /\s+/;

        my ( $author, $package ) = $data[2] =~ m|  (?:[A-Z\d-]/)?
                    (?:[A-Z\d-]{2}/)?
                    ([A-Z\d-]+) (?:/[\S]+)?/
                    ([^/]+)$
                |xsg;

        $data[2] =~ s|/[^/]+$||;

        my $aobj = $self->author_tree($author);
        unless ($aobj) {
            error(
                loc(
                    "No such author '%1' -- can't make module object "
                      . "'%2' that is supposed to belong to this author",
                    $author,
                    $data[0]
                )
            );
            next;
        }

        my $dslip;
        for my $item (qw[ statd stats statl stati statp ]) {
            $dslip .=
                $dslip_tree->{ $data[0] }->{$item}
              ? $dslip_tree->{ $data[0] }->{$item}
              : ' ';
        }

        $self->_add_module_object(
            module => $data[0], version => (
                $data[1] eq 'undef'
                ? '0.0'
                : $data[1]
            ),
            path => File::Spec::Unix->catfile(
                $conf->_get_mirror('base'), $data[2],
              ),  comment => $data[3], author => $aobj,
            package => $package,  description =>
              $dslip_tree->{ $data[0] }->{'description'},
            dslip => $dslip,
            mtime => '',
        ) or error( loc( "Could not add module '%1'", $data[0] ) );

        $args->{verbose}
          and (
            $idx++,

            ( $idx == $prce and ( $prc += 4, $idx = 0, print "." ) ),

            ( ( $prc % 10 ) or $idx or print $prc, '%' )
          );

    }

    $args->{verbose}
      and print "\n";

    return $self->_mtree;

}


sub __create_dslip_tree {
    my $self = shift;
    my %hash = @_;
    my $conf = $self->configure_object;

    my $tmpl = {
        path     => { default => $conf->get_conf('base') },
        verbose  => { default => $conf->get_conf('verbose') },
        uptodate => { default => 0 },
    };

    my $args = check( $tmpl, \%hash ) or return;

    my $file =
      File::Spec->catfile( $args->{path}, $conf->_get_source('dslip') );

    my $ae = Archive::Extract->new( archive => $file ) or return;
    my $out = STRIP_GZ_SUFFIX->($file);

    {
        local $Archive::Extract::PREFER_BIN = $conf->get_conf('prefer_bin');
        $ae->extract( to => $out ) or return;
    }

    my $in = $self->_get_file_contents( file => $out ) or return;

    unlink $out;

    my ( $ds_one, $ds_two ) = (
        $in =~ m|.+}\s+
                              (\$(?:CPAN::Modulelist::)?cols.*?)
                              (\$(?:CPAN::Modulelist::)?data.*)
                           |sx
    );

    my ( $cols, $data );
    {

        $cols = eval $ds_one;
        error( loc( "Error in eval of dslip source files: %1", $@ ) ) if $@;

        $data = eval $ds_two;
        error( loc( "Error in eval of dslip source files: %1", $@ ) ) if $@;

    }

    my $tree    = {};
    my $primary = "modid";

    for (@$data) {
        my %hash;
        @hash{@$cols} = @$_;
        $tree->{ $hash{$primary} } = \%hash;
    }

    return $tree;

}


sub _dslip_defs {
    my $self = shift;

    my $aref = [

        [
            q|Development Stage|,
            {
                i => loc('Idea, listed to gain consensus or as a placeholder'),
                c => loc('under construction but pre-alpha (not yet released)'),
                a => loc('Alpha testing'),
                b => loc('Beta testing'),
                R => loc('Released'),
                M => loc('Mature (no rigorous definition)'),
                S => loc('Standard, supplied with Perl 5'),
            }
        ],

        [
            q|Support Level|,
            {
                m => loc('Mailing-list'),
                d => loc('Developer'),
                u => loc('Usenet newsgroup comp.lang.perl.modules'),
                n => loc('None known, try comp.lang.perl.modules'),
                a =>
                  loc('Abandoned; volunteers welcome to take over maintenance'),
            }
        ],

        [
            q|Language Used|,
            {
                p => loc(
'Perl-only, no compiler needed, should be platform independent'
                ),
                c => loc('C and perl, a C compiler will be needed'),
                h => loc(
'Hybrid, written in perl with optional C code, no compiler needed'
                ),
                '+' => loc('C++ and perl, a C++ compiler will be needed'),
                o   => loc('perl and another language other than C or C++'),
            }
        ],

        [
            q|Interface Style|,
            {
                f => loc('plain Functions, no references used'),
                h => loc('hybrid, object and function interfaces available'),
                n => loc('no interface at all (huh?)'),
                r => loc('some use of unblessed References or ties'),
                O => loc(
'Object oriented using blessed references and/or inheritance'
                ),
            }
        ],

        [
            q|Public License|,
            {
                p => loc(
                    'Standard-Perl: user may choose between GPL and Artistic'),
                g => loc('GPL: GNU General Public License'),
                l => loc(
'LGPL: "GNU Lesser General Public License" (previously known as "GNU Library General Public License")'
                ),
                b => loc('BSD: The BSD License'),
                a => loc('Artistic license alone'),
                o =>
                  loc('other (but distribution allowed without restrictions)'),
            }
        ],
    ];

    return $aref;
}


sub _add_custom_module_source {
    my $self = shift;
    my $conf = $self->configure_object;
    my %hash = @_;

    my ( $verbose, $uri );
    my $tmpl = {
        verbose => {
            default => $conf->get_conf('verbose'),
            store   => \$verbose
        },
        uri => { required => 1, store => \$uri }
    };

    check( $tmpl, \%hash ) or return;

    my $index = $self->__custom_module_source_index_file( uri => $uri );

    if ( IS_FILE->($index) ) {
        msg( loc( "Source '%1' already added", $uri ) );
        return 1;
    }

    {
        my $dir = dirname($index);
        unless ( IS_DIR->($dir) ) {
            $self->_mkdir( dir => $dir ) or return;
        }
    }

    my $fh = OPEN_FILE->( $index => '>' ) or do {
        error( loc( "Could not open index file for '%1'", $uri ) );
        return;
    };

    close $fh or do {
        error( loc( "Could not write index file to disk for '%1'", $uri ) );
        return;
    };

    $self->__update_custom_module_source(
        remote  => $uri,
        local   => $index,
        verbose => $verbose,
      )
      or do {
        1 while unlink $index;
        return;
      };

    return $index;
}


sub __custom_module_source_index_file {
    my $self = shift;
    my $conf = $self->configure_object;
    my %hash = @_;

    my ( $verbose, $uri );
    my $tmpl = { uri => { required => 1, store => \$uri } };

    check( $tmpl, \%hash ) or return;

    my $index = File::Spec->catfile(
        $conf->get_conf('base'),
        $conf->_get_build('custom_sources'),
        $self->_uri_encode( uri => $uri ),
    );

    return $index;
}


sub _remove_custom_module_source {
    my $self = shift;
    my $conf = $self->configure_object;
    my %hash = @_;

    my ( $verbose, $uri );
    my $tmpl = {
        verbose => {
            default => $conf->get_conf('verbose'),
            store   => \$verbose
        },
        uri => { required => 1, store => \$uri }
    };

    check( $tmpl, \%hash ) or return;

    my %files = reverse $self->__list_custom_module_sources;

    my $file = $files{$uri};
    $file = $files{ lc $uri } if !defined($file) && ON_VMS;

    unless ( defined $file ) {
        error( loc( "No such custom source '%1'", $uri ) );
        return;
    }

    1 while unlink $file;

    if ( IS_FILE->($file) ) {
        error(
            loc(
                "Could not remove index file '%1' for custom source '%2'",
                $file, $uri
            )
        );
        return;
    }

    msg( loc( "Successfully removed index file for '%1'", $uri ), $verbose );

    return $file;
}


sub __list_custom_module_sources {
    my $self = shift;
    my $conf = $self->configure_object;

    my ($verbose);
    my $tmpl = {
        verbose => {
            default => $conf->get_conf('verbose'),
            store   => \$verbose
        },
    };

    my $dir = File::Spec->catdir(
        $conf->get_conf('base'),
        $conf->_get_build('custom_sources'),
    );

    unless ( IS_DIR->($dir) ) {
        msg( loc( "No '%1' dir, skipping custom sources", $dir ), $verbose );
        return;
    }

    my %files = map {
        my $org = $_;
        my $dec = $self->_uri_decode( uri => $_ );
        File::Spec->catfile( $dir, $org ) => $dec
    } grep { $_ !~ /^#/ } READ_DIR->($dir);

    return %files;
}


sub __update_custom_module_sources {
    my $self = shift;
    my $conf = $self->configure_object;
    my %hash = @_;

    my $verbose;
    my $tmpl = {
        verbose => {
            default => $conf->get_conf('verbose'),
            store   => \$verbose
        }
    };

    check( $tmpl, \%hash ) or return;

    my %files = $self->__list_custom_module_sources;

    my $fail;
    while ( my ( $local, $remote ) = each %files ) {

        $self->__update_custom_module_source(
            remote  => $remote,
            local   => $local,
            verbose => $verbose,
        ) or ( $fail++, next );
    }

    error( loc("Failed updating one or more remote sources files") ) if $fail;

    return if $fail;
    return 1;
}


sub __update_custom_module_source {
    my $self = shift;
    my $conf = $self->configure_object;
    my %hash = @_;

    my ( $verbose, $local, $remote );
    my $tmpl = {
        verbose => {
            default => $conf->get_conf('verbose'),
            store   => \$verbose
        },
        local  => { store    => \$local, allow => FILE_EXISTS },
        remote => { required => 1,       store => \$remote },
    };

    check( $tmpl, \%hash ) or return;

    msg( loc( "Updating sources from '%1'", $remote ), $verbose );

    $local ||= do {
        my %files = reverse $self->__list_custom_module_sources or do {
            error(
                loc(
                    "No custom modules sources defined -- need '%1' argument",
                    'local'
                )
            );
            return;
        };

        my $file = $files{$remote};
        $file = $files{ lc $remote } if !defined($file) && ON_VMS;

        $file or do {
            error(
                loc(
                    "Remote source '%1' unknown -- needs '%2' argument",
                    $remote, 'local'
                )
            );
            return;
        };
    };

    my $uri = join '/', $remote, $conf->_get_source('custom_index');
    my $ff = File::Fetch->new( uri => $uri );

    my $dir = tempdir( CLEANUP => 1 );

    my $res = do {
        local $File::Fetch::WARN    = 0;
        local $File::Fetch::TIMEOUT = $conf->get_conf('timeout');
        $ff->fetch( to => $dir );
    };

    unless ($res) {

        unless ( $ff->scheme eq 'file' ) {
            error(
                loc(
                    "Could not update sources from '%1': %2", $remote,
                    $ff->error
                )
            );
            return;

        }
        else {
            msg( loc( "No index file found at '%1', generating one", $ff->uri ),
                $verbose );

            my $ff_path = do {
                my $file_class = 'File::Spec';
                $file_class .= '::Unix' if ON_VMS;
                $file_class->catdir( File::Spec::Unix->splitdir( $ff->path ) );
            };

            $self->__write_custom_module_index(
                path    => $ff_path,
                to      => $local,
                verbose => $verbose,
            ) or return;

        }

    }
    else {
        $self->_move( file => $res, to => $local ) or return;
        $self->_update_timestamp( file => $local );

        msg( loc( "Index file saved to '%1'", $local ), $verbose );
    }

    return $local;
}


sub __write_custom_module_index {
    my $self = shift;
    my $conf = $self->configure_object;
    my %hash = @_;

    my ( $verbose, $path, $to );
    my $tmpl = {
        verbose => {
            default => $conf->get_conf('verbose'),
            store   => \$verbose
        },
        path => { required => 1, allow => DIR_EXISTS, store => \$path },
        to   => { store    => \$to },
    };

    check( $tmpl, \%hash ) or return;

    $to ||= File::Spec->catfile( $path, $conf->_get_source('custom_index') );

    my @files;
    require File::Find;
    File::Find::find(
        sub {
            my $ae = do {
                local $Archive::Extract::WARN = 0;
                local $Archive::Extract::WARN = 0;
                Archive::Extract->new( archive => $File::Find::name );
              }
              or return;

            $ae->type or return;

            my $copy = $File::Find::name;
            my $re   = quotemeta($path);
            $copy =~ s|^$re[\\/]?||i;

            push @files, $copy;

        },
        $path
    );

    {
        my $dir = dirname($to);
        unless ( IS_DIR->($dir) ) {
            $self->_mkdir( dir => $dir ) or return;
        }
    }

    my $fh = OPEN_FILE->( $to => '>' ) or return;

    print $fh "$_\n" for @files;
    close $fh;

    msg( loc( "Successfully written index file to '%1'", $to ), $verbose );

    return $to;
}


{
    my $auth_obj;

    sub __create_custom_module_entries {
        my $self = shift;
        my $conf = $self->configure_object;
        my %hash = @_;

        my $verbose;
        my $tmpl =
          { verbose =>
              { default => $conf->get_conf('verbose'), store => \$verbose }, };

        check( $tmpl, \%hash ) or return undef;

        my %files = $self->__list_custom_module_sources;

        while ( my ( $file, $name ) = each %files ) {

            msg( loc( "Adding packages from custom source '%1'", $name ),
                $verbose );

            my $fh = OPEN_FILE->($file) or next;

            while ( local $_ = <$fh> ) {
                chomp;
                next if /^#/;
                next unless /\S+/;

                my $parse = join '/', $name, $_;

                my $mod = $self->parse_module( module => $parse )
                  or ( error( loc( "Could not parse '%1'", $_ ) ), next );

                $auth_obj ||= do {
                    my $id = CUSTOM_AUTHOR_ID;

                    $self->author_tree->{$id} =
                      CPANPLUS::Module::Author::Fake->new( cpanid => $id );
                };

                $mod->author($auth_obj);

                if ( my $old_mod = $self->module_tree( $mod->module ) ) {

                    $mod->module( $old_mod->module ) if ON_VMS;

                    msg(
                        loc(
"About to overwrite module tree entry for '%1' with '%2'",
                            $mod->module,
                            $mod->package
                        ),
                        $verbose
                    );
                }

                $mod->description( loc( "Custom source from '%1'", $name ) );

                $self->module_tree->{ $mod->module } = $mod;
            }
        }

        return 1;
    }
}

1;
