use utf8;

package Koha::Plugin::Com::PTFSEurope::Crontab::Controller;

use Modern::Perl;
use Koha::Plugin::Com::PTFSEurope::Crontab;

use Mojo::Base 'Mojolicious::Controller';

use POSIX qw(strftime);
use Config::Crontab;

=head1 API

=head2 Class Methods

=head3 Method to update a cron block

=cut

sub add {
    my $c = shift->openapi->valid_input or return;

    my $ct = Config::Crontab->new();
    $ct->mode('block');
    $ct->read or do {
        return $c->render(
            status  => 500,
            openapi => { error => "Could not read crontab file" }
        );
    };

    my @id_lines =
      $ct->select( -type => 'comment', -data => "# BLOCKID: " );
    $id_lines[-1]->data() =~ /.*(\d+)/;
    my $final_id = $1;
    my $next_id = $final_id + 1;

    my $body     = $c->validation->param('body');

    # Construct new block
    my $lines;
    my $newblock = Config::Crontab::Block->new();
    push @{$lines},
      Config::Crontab::Comment->new( -data => "# BLOCKID: $next_id" );


    # Comments
    for my $comment ( @{ $body->{comments} } ) {
        push @{$lines}, Config::Crontab::Comment->new( -data => "# $comment" );
    }

    # Events
    for my $event ( @{ $body->{events} } ) {
        push @{$lines},
          Config::Crontab::Event->new( -datetime => $event->schedule, -command => $event->command );
    }

    ## TODO: Add Environment handling as needed?

    # Set block lines
    $newblock->lines($lines);

    # Append block
    $ct->last( $newblock );

    # Write to crontab
    $ct->write
      or do {
        return $c->render(
            status  => 500,
            openapi => { error => "Could not write to crontab: " . $ct->error }
        );
      };

    return $c->render(
        status  => 200,
        openapi => { success => Mojo::JSON->true }
    );
}

sub update {
    my $c = shift->openapi->valid_input or return;

    my $ct = Config::Crontab->new();
    $ct->mode('block');
    $ct->read or do {
        return $c->render(
            status  => 500,
            openapi => { error => "Could not read crontab file" }
        );
    };

    # Find block
    my $block_id = $c->validation->param('block_id');
    my @id_lines =
      $ct->select( -type => 'comment', -data => "# BLOCKID: $block_id" );
    unless ( scalar @id_lines == 1 ) {
        return $c->render(
            status  => 500,
            openapi => { error => "Could not uniquely identify cronjob block." }
        );
    }

    my $block = $ct->block( $id_lines[0] );

    # Construct new block
    my $lines;
    my $newblock = Config::Crontab::Block->new();
    push @{$lines},
      Config::Crontab::Comment->new( -data => "# BLOCKID: $block_id" );

    my $body     = $c->validation->param('body');
    for my $comment ( @{ $body->{comments} } ) {
        push @{$lines}, Config::Crontab::Comment->new( -data => "# $comment" );
    }
    ## TODO: Add Event and Environment handling as needed?

    # Replace block
    $ct->replace( $block, $newblock );

    # Write to crontab
    $ct->write
      or do {
        return $c->render(
            status  => 500,
            openapi => { error => "Could not write to crontab: " . $ct->error }
        );
      };

    return $c->render(
        status  => 200,
        openapi => { success => Mojo::JSON->true }
    );
}

sub backup {
    my $c = shift->openapi->valid_input or return;

    my $plugin =
      Koha::Plugin::Com::PTFSEurope::Crontab->new;

    my $ct = Config::Crontab->new();
    $ct->mode('block');
    $ct->read or do {
        return $c->render(
            status  => 500,
            openapi => { error => "Could not read crontab file" }
        );
    };

    # Take a backup
    my $path = $plugin->mbf_dir . '/backups/';
    my $now_string = strftime "%F_%H-%M-%S", localtime;
    my $filename = $path . 'backup_' . $now_string;
    $ct->write("$filename") or do {
         return $c->render(
            status  => 500,
            openapi => { error => "Could not write to backup: " . $ct->error }
        );
    };

    return $c->render(
        status => 200,
        openapi => { filename => "backup_" . $now_string }
    );
}

1;
