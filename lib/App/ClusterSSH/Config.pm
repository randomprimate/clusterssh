package App::ClusterSSH::Config;

use strict;
use warnings;

use version;
our $VERSION = version->new('0.01');

use Carp;
use Try::Tiny;

use FindBin qw($Script);

use base qw/ App::ClusterSSH::Base /;

my %clusters;
my @app_specific   = (qw/ command title comms method ssh rsh telnet ccon /);
my %default_config = (
    terminal                   => "xterm",
    terminal_args              => "",
    terminal_title_opt         => "-T",
    terminal_colorize          => 1,
    terminal_bg_style          => 'dark',
    terminal_allow_send_events => "-xrm '*.VT100.allowSendEvents:true'",
    terminal_font              => "6x13",
    terminal_size              => "80x24",

    use_hotkeys             => "yes",
    key_quit                => "Control-q",
    key_addhost             => "Control-Shift-plus",
    key_clientname          => "Alt-n",
    key_history             => "Alt-h",
    key_retilehosts         => "Alt-r",
    key_paste               => "Control-v",
    mouse_paste             => "Button-2",
    auto_quit               => "yes",
    window_tiling           => "yes",
    window_tiling_direction => "right",
    console_position        => "",

    screen_reserve_top    => 0,
    screen_reserve_bottom => 60,
    screen_reserve_left   => 0,
    screen_reserve_right  => 0,

    terminal_reserve_top    => 5,
    terminal_reserve_bottom => 0,
    terminal_reserve_left   => 5,
    terminal_reserve_right  => 0,

    terminal_decoration_height => 10,
    terminal_decoration_width  => 8,

    rsh_args    => "",
    telnet_args => "",
    ssh_args    => "",

    extra_cluster_file => "",

    unmap_on_redraw => "no",    # Debian #329440

    show_history   => 0,
    history_width  => 40,
    history_height => 10,

    command             => q{},
    max_host_menu_items => 30,

    max_addhost_menu_cluster_items => 6,
    menu_send_autotearoff          => 0,
    menu_host_autotearoff          => 0,

    send_menu_xml_file => $ENV{HOME} . '/.csshrc_send_menu',
);

sub new {
    my ( $class, %args ) = @_;

    my $self = $class->SUPER::new(%default_config);

    ( my $comms = $Script ) =~ s/^c//;
    $self->{comms} = $comms;

    # list of allowed comms methods
    if ( 'ssh rsh telnet console' !~ m/\B$comms\B/ ) {
        $self->{comms} = 'ssh';
    }

    if($self->{comms} && (! $self->{ $self->{comms} } || ! -e $self->{ $self->{comms} } ) ) {
        $self->{ $self->{comms} } = $self->find_binary( $self->{ comms } );
    }

    $self->{title} = uc($Script);

    return $self->validate_args(%args);
}

sub validate_args {
    my ( $self, %args ) = @_;

    my @unknown_config = ();

    foreach my $config ( sort( keys(%args) ) ) {
        if ( grep /$config/, @app_specific ) {

            #     $self->{$config} ||= 'unknown';
            next;
        }

        if ( exists $self->{$config} ) {
            $self->{$config} = $args{$config};
        }
        else {
            push( @unknown_config, $config );
        }
    }

    if (@unknown_config) {
        croak(
            App::ClusterSSH::Exception::Config->throw(
                unknown_config => \@unknown_config,
                error          => $self->loc(
                    'Unknown configuration parameters: [_1]',
                    join( ',', @unknown_config )
                )
            )
        );
    }

    return $self;
}

sub parse_config_file {
    my ( $self, $config_file ) = @_;

    $self->debug( 2, 'Loading in config file: ', $config_file );

    if ( !-e $config_file || !-r $config_file ) {
        croak(
            App::ClusterSSH::Exception::Config->throw(
                error => $self->loc(
                    'File [_1] does not exist or cannot be read', $config_file
                ),
            ),
        );
    }

    open( CFG, $config_file ) or die("Couldnt open $config_file: $!");
    my $l;
    my %read_config;
    while ( defined( $l = <CFG> ) ) {
        next
            if ( $l =~ /^\s*$/ || $l =~ /^#/ )
            ;    # ignore blank lines & commented lines
        $l =~ s/#.*//;     # remove comments from remaining lines
        $l =~ s/\s*$//;    # remove trailing whitespace

        # look for continuation lines
        chomp $l;
        if ( $l =~ s/\\\s*$// ) {
            $l .= <CFG>;
            redo unless eof(CFG);
        }

        next unless $l =~ m/\s*(\S+)\s*=\s*(.*)\s*/;
        my ( $key, $value ) = ( $1, $2 );
        if ( defined $key && defined $value ) {
            $read_config{$key} = $value;
            $self->debug( 3, "$key=$value" );
        }
    }
    close(CFG);

    # grab any clusters from the config before validating it
    if ( $read_config{clusters} ) {
        carp("TODO: deal with clusters");
        $self->debug( 3, "Picked up clusters defined in $config_file" );
        foreach my $cluster ( sort split / /, $read_config{clusters} ) {
            delete( $read_config{$cluster} );
        }
        delete( $read_config{clusters} );
    }

    # tidy up entries, just in case
    $read_config{terminal_font} =~ s/['"]//g
        if ( $read_config{terminal_font} );

    $self->validate_args(%read_config);
}

sub load_configs {
    my ( $self, @configs ) = @_;

    if ( -e $ENV{HOME} . '/.csshrc' ) {
        warn(
            $self->loc(
                'NOTICE: [_1] is no longer used - please see documentation and remove',
                $ENV{HOME} . '/.csshrc'
            ),
            $/
        );
    }

    for my $config (
        '/etc/csshrc',
        $ENV{HOME} . '/.csshrc',
        $ENV{HOME} . '/.clusterssh/config',
        )
    {
        $self->parse_config_file($config) if ( -e $config );
    }

    # write out default config file if necesasry
    try {
        $self->write_user_config_file();
    }
    catch {
        warn $_, $/;
    };

    # Attempt to load in provided config files.  Also look for anything
    # relative to config directory
    for my $config (@configs) {
        next unless ($config);    # can be null when passed from Getopt::Long
        $self->parse_config_file($config) if ( -e $config );

        my $file = $ENV{HOME} . '/.clusterssh/config_' . $config;
        $self->parse_config_file($file) if ( -e $file );
    }

    return $self;
}

sub write_user_config_file {
    my ($self) = @_;

    return if ( -f "$ENV{HOME}/.clusterssh/config" );

    if ( !-d "$ENV{HOME}/.clusterssh" ) {
        if ( !mkdir("$ENV{HOME}/.clusterssh") ) {
            croak(
                App::ClusterSSH::Exception::Config->throw(
                    error => $self->loc(
                        'Unable to create directory [_1]: [_2]',
                        '$HOME/.clusterssh', $!
                    ),
                ),
            );

        }
    }

    if ( open( CONFIG, ">", "$ENV{HOME}/.clusterssh/config" ) ) {
        foreach ( sort( keys(%$self) ) ) {
            print CONFIG "$_=$self->{$_}\n";
        }
        close(CONFIG);
    }
    else {
        croak(
            App::ClusterSSH::Exception::Config->throw(
                error => $self->loc(
                    'Unable to write default [_1]: [_2]',
                    '$HOME/.clusterssh/config',
                    $!
                ),
            ),
        );
    }
    return $self;
}

# could use File::Which for some of this but we also search a few other places
# just in case $PATH isnt set up right
sub find_binary {
    my ( $self, $binary ) = @_;

    if ( !$binary ) {
        croak(
            App::ClusterSSH::Exception::Config->throw(
                error => $self->loc('argument not provided'),
            ),
        );
    }

    $self->debug( 2, "Looking for $binary" );
    my $path;
    if ( !-x $binary || substr( $binary, 0, 1 ) ne '/' ) {

        foreach (
            split( /:/, $ENV{PATH} ), qw!
            /bin
            /sbin
            /usr/sbin
            /usr/bin
            /usr/local/bin
            /usr/local/sbin
            /opt/local/bin
            /opt/local/sbin
            !
            )
        {
            $self->debug( 3, "Looking in $_" );

            if ( -f $_ . '/' . $binary && -x $_ . '/' . $binary ) {
                $path = $_ . '/' . $binary;
                $self->debug( 2, "Found at $path" );
                last;
            }
        }
    }
    else {
        $self->debug( 2, "Already configured OK" );
        $path = $binary;
    }
    if ( !$path || !-f $path || !-x $path ) {
        croak(
            App::ClusterSSH::Exception::Config->throw(
                error => $self->loc(
                    '"[_1]" binary not found - please amend $PATH or the cssh config file',
                    $binary
                ),
            ),
        );
    }

    chomp($path);
    return $path;
}

sub dump {
    my ( $self, $no_exit, ) = @_;

    $self->debug( 3, 'Dumping config to STDOUT' );
    print( '# Configuration dump produced by "cssh -u"', $/ );

    foreach my $key ( sort keys %$self ) {
        if ( grep /$key/, @app_specific ) {
            next;
        }
        print $key, '=', $self->{$key}, $/;
    }

    $self->exit if ( !$no_exit );
}

#use overload (
#    q{""} => sub {
#        my ($self) = @_;
#        return $self->{hostname};
#    },
#    fallback => 1,
#);

1;

=pod

=head1 NAME

ClusterSSH::Config

=head1 SYNOPSIS

=head1 DESCRIPTION

Object representing application configuration

=head1 METHODS

=over 4

=item $host=ClusterSSH::Config->new ({ })

Create a new configuration object.

=item $config->parse_config_file('<filename>');

Read in configuration from given filename

=item $config->validate_args();

Validate and apply all configuration loaded at this point

=item $path = $config->find_binary('<name>');

Locate the binary <name> and return the full path.  Doesn't just search 
$PATH in case the environment isn't set up correctly

=item $config->load_configs(@extra);

Load up configuration from known locations (warn if .csshrc file found) and 
load in option files as necessary.

=item $config->write_user_config_file();

Write out default $HOME/.clusterssh/config file (before option config files
are loaded).

=item $config->dump()

Write currently defined configuration to STDOUT

=back

=head1 AUTHOR

Duncan Ferguson, C<< <duncan_j_ferguson at yahoo.co.uk> >>

=head1 LICENSE AND COPYRIGHT

Copyright 1999-2010 Duncan Ferguson.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.

=cut

1;