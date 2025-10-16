package Koha::Cron::Script;

# Script discovery and parsing operations

use Modern::Perl;
use File::Find;
use File::Basename;
use Pod::Usage;
use Try::Tiny;

=head1 NAME

Koha::Cron::Script - Script discovery and parsing

=head1 SYNOPSIS

    my $script = Koha::Cron::Script->new({
        crontab => $crontab_instance,
    });

    my $scripts = $script->get_available_scripts();
    my $doc = $script->parse_script_documentation('/path/to/script.pl');

=head1 DESCRIPTION

This module handles script discovery from KOHA_CRON_PATH and parsing of
POD documentation and GetOptions specifications.

=head1 METHODS

=cut

=head2 new

Constructor

    my $script = Koha::Cron::Script->new({
        crontab => $crontab_instance,  # Required: Crontab model instance
    });

=cut

sub new {
    my ( $class, $args ) = @_;

    die "crontab instance required" unless $args->{crontab};

    my $self = {
        crontab => $args->{crontab},
    };

    bless $self, $class;

    return $self;
}

=head2 get_available_scripts

Get list of available scripts from KOHA_CRON_PATH

    my $scripts = $script->get_available_scripts();

Returns arrayref of hashrefs with script metadata

=cut

sub get_available_scripts {
    my ($self) = @_;

    # Get KOHA_CRON_PATH from crontab environment
    my $ct = $self->{crontab}->read();
    return [] unless $ct;

    my $cron_path;
    my @env_lines = $ct->select( -type => 'env' );
    for my $env (@env_lines) {
        if ( $env->name eq 'KOHA_CRON_PATH' ) {
            $cron_path = $env->value;
            last;
        }
    }

    return [] unless $cron_path && -d $cron_path;

    my @scripts;
    find(
        sub {
            my $abs_path = $File::Find::name;
            my $rel_path = $abs_path;
            $rel_path =~ s/^\Q$cron_path\E//;
            $rel_path = '$KOHA_CRON_PATH' . $rel_path;

            # Only include .pl and .sh files
            if ( -f $abs_path
                && ( $abs_path =~ /\.pl$/ || $abs_path =~ /\.sh$/ ) )
            {
                my $type     = $abs_path =~ /\.pl$/ ? 'perl' : 'shell';
                my $basename = basename($abs_path);

                # Get brief description from POD NAME section for perl scripts
                my $description = '';
                if ( $type eq 'perl' ) {
                    my $doc = $self->parse_script_documentation($abs_path);
                    $description = $doc->{name_brief} || '';
                }

                push @scripts,
                  {
                    name          => $basename,
                    path          => $abs_path,
                    relative_path => $rel_path,
                    type          => $type,
                    description   => $description,
                  };
            }
        },
        $cron_path
    );

    # Sort by name
    @scripts = sort { $a->{name} cmp $b->{name} } @scripts;

    return \@scripts;
}

=head2 parse_script_documentation

Parse POD documentation from a Perl script using Pod::Usage

    my $doc = $script->parse_script_documentation('/path/to/script.pl');

Returns hashref with: name_brief, usage_text

=cut

sub parse_script_documentation {
    my ( $self, $script_path ) = @_;

    return {} unless -f $script_path;

    my %doc = (
        name_brief => '',
        usage_text => '',
    );

    # Extract brief description from DESCRIPTION section
    try {
        my $name_output = '';
        open my $name_fh, '>', \$name_output;
        pod2usage(
            -input    => $script_path,
            -output   => $name_fh,
            -sections => 'DESCRIPTION',
            -verbose  => 99,
            -exitval  => 'NOEXIT'
        );
        close $name_fh;

        $doc{name_brief} = $name_output;
    }
    catch {
        # If DESCRIPTION section fails, that's okay
    };

    # Extract full usage documentation (verbose level 1)
    try {
        my $usage_output = '';
        open my $usage_fh, '>', \$usage_output;
        pod2usage(
            -input   => $script_path,
            -output  => $usage_fh,
            -verbose => 1,
            -exitval => 'NOEXIT'
        );
        close $usage_fh;

        $doc{usage_text} = $usage_output;
    }
    catch {
        warn "Failed to extract POD from $script_path: $_";
        $doc{usage_text} = "No documentation available.\n";
    };

    return \%doc;
}

=head2 parse_script_options

Parse command-line options from a Perl script's GetOptions call

    my $options = $script->parse_script_options('/path/to/script.pl');

Returns arrayref of hashrefs with: name, short_name, type, required

=cut

sub parse_script_options {
    my ( $self, $script_path ) = @_;

    return [] unless -f $script_path;

    # Parse GetOptions from the script itself to get option names and types
    my @options;
    open my $fh, '<', $script_path or return [];
    my $in_getoptions    = 0;
    my $getoptions_block = '';

    while ( my $line = <$fh> ) {
        if ( $line =~ /GetOptions\s*\(/i ) {
            $in_getoptions = 1;
        }

        if ($in_getoptions) {
            $getoptions_block .= $line;
            if ( $line =~ /\)\s*;/ || $line =~ /\|\|\s*pod2usage/ ) {
                last;
            }
        }
    }
    close $fh;

    # Parse option specifications from GetOptions block
    while ( $getoptions_block =~ /'([^']+)'\s*=>/g ) {
        my $spec = $1;
        my ( $name, $short_name, $type, $required ) = ( '', '', 'boolean', 0 );

        # Parse spec format: 'name|alias:type'
        if ( $spec =~ /^([\w-]+)(?:\|(\w+))?(?:([=:])(\w+))?$/ ) {
            $name       = $1;
            $short_name = $2 || '';
            my $modifier  = $3 || '';
            my $type_code = $4 || '';

            # Determine type
            if ( $modifier eq '=' ) {
                $required = 1;
                if ( $type_code eq 's' ) {
                    $type = 'string';
                }
                elsif ( $type_code eq 'i' ) {
                    $type = 'integer';
                }
                elsif ( $type_code eq 'f' ) {
                    $type = 'float';
                }
            }
            elsif ( $modifier eq ':' ) {
                $required = 0;
                if ( $type_code eq 's' ) {
                    $type = 'string';
                }
                elsif ( $type_code eq 'i' ) {
                    $type = 'integer';
                }
                elsif ( $type_code eq 'f' ) {
                    $type = 'float';
                }
            }

            push @options,
              {
                name       => $name,
                short_name => $short_name,
                type       => $type,
                required   => $required,
              };
        }
    }

    return \@options;
}

=head2 validate_command

Validate that a command uses an approved script from the available scripts list

    my $result = $script->validate_command($command);

Returns hashref with: valid => 1/0, error => string (if invalid), script => matched script hashref (if valid)

=cut

sub validate_command {
    my ( $self, $command ) = @_;

    return { valid => 0, error => "Command is required" } unless $command;

    # Extract the script path (first token before any parameters)
    my @parts = split /\s+/, $command;
    my $script_path = $parts[0];

    return { valid => 0, error => "Empty command" } unless $script_path;

    # Get list of available scripts
    my $available_scripts = $self->get_available_scripts();

    # Try to match against available scripts
    my $matched_script;
    for my $script (@$available_scripts) {
        if ( $script->{relative_path} eq $script_path ) {
            $matched_script = $script;
            last;
        }
    }

    unless ($matched_script) {
        return {
            valid => 0,
            error =>
"Command must use a script from the approved list. Use the script browser to select a valid script. Provided: $script_path"
        };
    }

    # Command is valid
    return { valid => 1, script => $matched_script };
}

1;

=head1 AUTHOR

Martin Renvoize <martin.renvoize@openfifth.co.uk>

=head1 COPYRIGHT

Copyright 2025 Open Fifth

=head1 LICENSE

This file is part of Koha.

Koha is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation; either version 3 of the License, or (at your option) any later version.

=cut
