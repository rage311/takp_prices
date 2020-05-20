#!/usr/bin/env perl

use 5.028;

use Mojolicious::Lite -signatures, -async_await;
use Mojo::JSON qw(to_json from_json);
use Mojo::Util qw(secure_compare dumper);
use Mojo::SQLite;
use IO::Compress::Gzip 'gzip';
use Email::Stuffer;

use constant DEBUG => $ENV{DEBUG} // 1;

helper sql => sub {
  state $sql = Mojo::SQLite->new('./takp_prices.db')->max_connections(10)
};

helper last_seen_all => sub ($c) {
  return $c->sql->db->query(q{
      SELECT
        item_id,
        STRFTIME('%Y-%m-%dT%H:%M:%SZ', MAX(timestamp)) AS timestamp,
        JULIANDAY('now') - JULIANDAY(MAX(timestamp))   AS days_diff
      FROM
        instances
      GROUP BY
        item_id
    },
  )->hashes;
};

helper last_seen => sub ($c, $id) {
  return $c->sql->db->query(q{
      SELECT
        STRFTIME('%Y-%m-%dT%H:%M:%SZ', MAX(timestamp)) AS timestamp,
        JULIANDAY('now') - JULIANDAY(MAX(timestamp))   AS days_diff
      FROM
        instances
      WHERE
        item_id = ?
    },
    $id
  )->hash;
};

helper price_data_all => sub ($c, $days = 3650) {
  my $price_agg = $c->sql->db->query(q{
      SELECT
        item_id,
        COUNT(price_pp) AS count,
        AVG(price_pp)   AS avg,
        MIN(price_pp)   AS min,
        MAX(price_pp)   AS max
      FROM
        instances_unique
      WHERE
        timestamp > DATETIME('now', '-' || ? || ' day')
      GROUP BY
        item_id
    },
    abs($days),
  )->hashes;
};

helper std_dev => sub ($c, $id, $days = 30) {
  my $instances = $c->sql->db->query(q{
        SELECT
          price_cp
        FROM
          instances
        WHERE
          item_id = ?
          AND timestamp > DATETIME('now', '-' || ? || ' day')
      },
      $id,
      $days,
    )->hashes
    ->map(sub { $_->{price_cp} });

  my $mean = $instances->reduce(sub { $a + $b }, 0) / @$instances;
  my $std_dev =
    sqrt($instances->reduce(sub { $a + ($b - $mean) ** 2 }, 0) / @$instances);

  say $instances->join("\n");
  say int($std_dev / 1000);

  return int($std_dev / 1000);
};

get '/std_dev' => sub ($c) {
  $c->render(text => $c->std_dev($c->param('id'), 30));
};

helper price_median => sub ($c, $id, $days = 3650) {
  my $count = $c->sql->db->query(q{
      SELECT
        COUNT(*) AS count
      FROM
        instances_unique
      WHERE
        item_id = ?
        AND timestamp > DATETIME('now', '-' || ? || ' day')
    },
    $id,
    $days
  )->hash->{count};

  return { median => undef } unless $count;

  return $c->sql->db->query(q{
      SELECT
        avg(price_pp) AS median
      FROM (
        SELECT
          price_pp
        FROM
          instances_unique
        WHERE
          item_id = ?
          AND timestamp > DATETIME('now', '-' || ? || ' day')
        ORDER BY
          price_pp
        LIMIT
          2 - ? % 2
        OFFSET
          (? - 1) / 2
      )
    },
    $id,
    $days,
    $count,
    $count,
  )->hash;
};

helper price_data => sub ($c, $id, $days = 3650) {
  return $c->sql->db->query(q{
      SELECT
        COUNT(price_pp) AS count,
        AVG(price_pp)   AS avg,
        MIN(price_pp)   AS min,
        MAX(price_pp)   AS max
      FROM
        instances_unique
      WHERE
        item_id = ?
        AND timestamp > DATETIME('now', '-' || ? || ' day')
    },
    $id,
    abs($days),
  )->hash;
};

helper search_items => sub ($c, $name = '') {
  return $c->sql->db->query(q{
      SELECT id, name FROM items WHERE name LIKE '%' || ? || '%'
    },
    $name,
  )->hashes;
};

helper find_item_by_id => sub ($c, $id) {
  return $c->sql->db->select('items', ['id', 'name'], {id => $id})->hash // {};
};

helper find_items_by_id => sub ($c, $ids = []) {
  my $query_string = <<EOF;
SELECT items.id, items.name FROM items JOIN instances ON items.id=instances.item_id
EOF
  $query_string .= ' WHERE items.id IN (' . join(',', ('?') x @$ids) . ')' if @$ids;
  $query_string .= ' GROUP BY items.id';

  return $c->sql->db->query($query_string, @$ids)->hashes;
};

helper item_exists_or_insert => sub ($c, $item_id, $item_name) {
  $c->sql->db->insert('items', { id => $item_id, name => $item_name })
    unless $c->sql->db->select('items', [ 'id' ], { id => $item_id })->hash;
};

helper insert_instance => sub ($c, $instance) {
  eval {
    $c->sql->db->insert('instances', {
      item_id   => $instance->{item_id},
      quantity  => $instance->{quantity},
      trader_id => $instance->{trader_id},
      price_cp  => $instance->{price_cp},
      price_pp  => $instance->{price_pp},
      bytes     => $instance->{bytes},
    });
  };
  warn "$@\n" if $@ && DEBUG();
  return 1;
};

helper price_agg => sub ($c, $id) {
  my $agg = {
    '30_day' => $c->price_data($id, 30),
    '90_day' => $c->price_data($id, 90),
    'all'    => $c->price_data($id),
  };

  $agg->{'30_day'}{median} = $c->price_median($id, 30)->{median};
  $agg->{'90_day'}{median} = $c->price_median($id, 90)->{median};
  $agg->{'all'}{median}    = $c->price_median($id)->{median};

  return $agg;
};

helper stats_html_all => sub ($c) {
  return $c->sql->db->select(items => ['id','stats_html'])->hashes;
};

helper get_items => sub ($c, $items) {
  return [] unless @$items;

  my $prices_all = { map {
    delete $_->{item_id} => $_
  } $c->price_data_all(30)->@* };

  my $last_seen_all = { map {
    delete $_->{item_id} => $_
  } $c->last_seen_all()->@* };

  my $stats_html_all = { map {
    $_->{stats_html} =~ s{src="[^"]+?(item_\d+\.gif)"}{src="/img/$1"}g
      if $_->{stats_html};
    delete $_->{id} => $_->{stats_html}
  } $c->stats_html_all()->@* };

  my $all_items = [ map {
    my $id = $_->{id};

    {
      id         => $id,
      name       => $_->{name},
      last_seen  => $last_seen_all->{$id},
      price_agg  => { '30_day' => $prices_all->{$id} },
      stats_html => $stats_html_all->{$id},
    }
  } @$items ];

  return $all_items;
};

helper unique_instances => sub ($c, $item_id) {
  return $c->sql->db->query(q{
      SELECT
        STRFTIME('%Y-%m-%dT%H:%M:%SZ', timestamp) AS timestamp,
        quantity,
        trader_id,
        price_pp
      FROM
        instances_unique
      WHERE
        item_id = ?
    },
    $item_id,
  )->hashes;
};

get '/api/item' => sub ($c) {
  return $c->render(json => {}) unless my $id = $c->param('id');

  my $item_data = $c->find_item_by_id($id);
  return $c->render(json => {}) unless %$item_data;

  $item_data->{instances} = $c->unique_instances($id);
  $item_data->{price_agg} = $c->price_agg($id);

  $c->render(json => $item_data);
};

helper get_items_sorted => sub ($c) {
  return [ sort {
    fc $a->{name} cmp fc $b->{name}
  } $c->get_items($c->find_items_by_id())->@* ];
};

helper all_items_cache => sub ($c) {
  return $c->sql->db->select(all_items_cache => '*' => { id => 1 })
    ->hash->{json};
};

helper all_items => sub ($c) {
  return $c->all_items_cache();
};

get '/api/items' => sub ($c) {
  my $output = $c->all_items();

  $c->res->headers->content_type('application/json');
  return $c->write($output) unless
    ($c->req->headers->accept_encoding // '') =~ /gzip/i;

  $c->res->headers->append(Vary => 'Accept-Encoding');

  $c->res->headers->content_encoding('gzip');
  gzip \$output, \my $compressed;

  return $c->write($compressed);
};

helper item_stats => sub ($c, $id) {
  my $html = $c->sql->db->select(items => ['id','stats_html'], {id => $id})
    ->hash->{stats_html};

  say $html if $html;
  $html =~ s{src="[^"]+?(item_\d+\.gif)"}{src="/img/$1"}g if $html;
  return $c->render(text => $html =~ s/(<br>)+/<br>/gr) if $html;

  $c->ua->get_p("https://www.takproject.net/allaclone/item.php?id=$id")
    ->then(sub ($tx) {
        $html = $tx->result
          ->dom
          ->at('div.item-wrapper')
          ->parent
          ->content;
        $html =~ s/(<br>)+/<br>/g;
        $c->sql->db->update('items', {stats_html => $html}, {id => $id});
        $html =~ s{src="[^"]+?(item_\d+\.gif)"}{src="/img/$1"}g if $html;
        return $c->render(text => $html);
    });
};

get '/api/item_stats_html' => sub ($c) {
  return $c->render(text => '<div></div>') unless my $id = $c->param('id');
  $c->render_later;
  $c->item_stats($id);
};

get '/api/search' => sub ($c) {
  return $c->render(status => 400) unless
    my $name = $c->req->param('name');

  $c->render(json => $c->get_items($c->search_items($name)));
};

post '/packet' => sub ($c) {
  return $c->render(data => 0, status => 401) unless
    secure_compare $c->req->param('api_key'), 'super-$3creT-API-key';

  return $c->render(data => 0, status => 400)
    unless my $instances = from_json $c->req->param('payload');

  $c->render(data => 1, status => 200);

  Mojo::IOLoop->next_tick(sub {
    for my $instance (@$instances) {
      say dumper $instance;
      $c->item_exists_or_insert($instance->{item_id}, $instance->{item_name});
      $c->insert_instance($instance);
      $c->alert_subscribers($instance);
    }
  });
};

get '/item' => sub ($c) {
  $c->flash(message => 'Invalid request') and return $c->redirect_to('/')
    unless my $id = $c->param('id');

  $c->render(item => id => $id);
};

get '/img/ajax-loader.gif' => sub ($c) {
  $c->res->headers->cache_control(
    'private, max-age=0, no-cache, no-store, must-revalidate'
  );
  $c->reply->static('img/monograms/' . int(rand(16) + 1) . '.gif');
};

get '/' => sub ($c) {
  my $items = eval { from_json $c->all_items() };
  $c->stash(items => $items);
} => 'index';


sub insert_cache ($c) {
  my $items = $c->get_items_sorted();
  return unless @$items;
  $c->sql->db->query('DELETE FROM all_items_cache');
  $c->sql->db->insert(all_items_cache => {
    id   => 1,
    json => to_json($items)
  });
}

sub update_cache ($c) {
  $c->sql->db->update(
    all_items_cache => {
      timestamp => \'CURRENT_TIMESTAMP',
      json      => to_json($c->get_items_sorted())
    }, {
      id => 1
    });
}


srand;
app->secrets(['lots of secret characters in here']);
app->renderer->compress(1);
Mojo::IOLoop->subprocess(sub { insert_cache(app); 1 }, sub {} );
Mojo::IOLoop->recurring(300 => sub {
  Mojo::IOLoop->subprocess( sub { update_cache(app); 1 }, sub {})
});
app->start;

