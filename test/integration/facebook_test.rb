# encoding: utf-8
require 'integration_test_helper'

class FacebookTest < ActiveSupport::TestCase

  # set system mode to done / to activate
  Setting.set('system_init_done', true)

  # needed to check correct behavior
  group = Group.create_if_not_exists(
    name: 'Facebook',
    note: 'All Facebook feed posts.',
    updated_by_id: 1,
    created_by_id: 1
  )

  # account config
  if !ENV['FACEBOOK_USER']
    raise "ERROR: Need FACEBOOK_USER - hint FACEBOOK_USER='name:1234:access_token'"
  end
  user_name         = ENV['FACEBOOK_USER'].split(':')[0]
  user_id           = ENV['FACEBOOK_USER'].split(':')[1]
  user_access_token = ENV['FACEBOOK_USER'].split(':')[2]

  if !ENV['FACEBOOK_PAGE']
    raise "ERROR: Need FACEBOOK_PAGE - hint FACEBOOK_PAGE='name:1234:access_token'"
  end
  page_name = ENV['FACEBOOK_PAGE'].split(':')[0]
  page_id = ENV['FACEBOOK_PAGE'].split(':')[1]
  page_access_token = ENV['FACEBOOK_PAGE'].split(':')[2]

  if !ENV['FACEBOOK_CUSTOMER']
    raise "ERROR: Need FACEBOOK_CUSTOMER - hint FACEBOOK_CUSTOMER='name:1234:access_token'"
  end
  customer_name = ENV['FACEBOOK_CUSTOMER'].split(':')[0]
  customer_id = ENV['FACEBOOK_CUSTOMER'].split(':')[1]
  customer_access_token = ENV['FACEBOOK_CUSTOMER'].split(':')[2]

  provider_options = {
    adapter: 'facebook',
    auth: {
      access_token: user_access_token
    },
    user: {
      name: user_name,
      id: user_id,
    },
    pages: [
      {
        'id' => page_id,
        'name' => page_name,
        'access_token' => page_access_token,
      }
    ],
    sync: {
      pages: {
        page_id => { 'group_id' => group.id.to_s },
      }
    }
  }

  # add channel
  current = Channel.where(area: 'Facebook::Account')
  current.each(&:destroy)
  Channel.create(
    area:          'Facebook::Account',
    options:       provider_options,
    active:        true,
    created_by_id: 1,
    updated_by_id: 1,
  )

  # check users account
  test 'a - user account' do
    client = Facebook.new(user_access_token)
    current_user = client.current_user
    assert_equal(user_id, current_user['id'])
    assert_equal(user_name, current_user['name'])
  end

  # check available pages
  test 'b - available pages' do
    client = Facebook.new(user_access_token)
    page_found = false
    client.pages.each {|page|
      next if page[:name] != page_name
      page_found = true
      assert_equal(page_id, page[:id])
      assert_equal(page_name, page[:name])
    }
    assert(page_found, "Page lookup for '#{page_name}'")
  end

  # check access to pages
  test 'c - page access' do
    page_found = false
    provider_options[:pages].each {|page|
      client = Facebook.new(page['access_token'])
      current_user = client.current_user
      next if page['name'] != page_name
      page_found = true
      assert_equal(page_id, current_user['id'])
      assert_equal(page_name, current_user['name'])
    }

    assert(page_found, "Page lookup for '#{page_name}'")
  end

  # check page account
  test 'd - page account' do
    client = Facebook.new(page_access_token)
    current_user = client.current_user
    assert_equal(page_id, current_user['id'])
    assert_equal(page_name, current_user['name'])
  end

  test 'e - feed post to ticket' do

    customer_client = Koala::Facebook::API.new(customer_access_token)
    message         = "I've got an issue with my hat, serial number ##{rand(99_999)}"
    post            = customer_client.put_wall_post(message, {}, page_id)

    # fetch check system account
    Channel.fetch

    # check if first article has been created
    article = Ticket::Article.find_by(message_id: post['id'])

    assert(article, "article post '#{post['id']}' imported")
    assert_equal(article.from, customer_name, 'ticket article inbound body')
    assert_equal(article.to, page_name, 'ticket article inbound body')
    assert_equal(article.body, message, 'ticket article inbound body')
    assert_equal(1, article.ticket.articles.count, 'ticket article inbound count')
    assert_equal(message, article.ticket.articles.last.body, 'ticket article inbound body')

    # check customer
    customer = article.ticket.customer
    assert_equal('Bernd', customer.firstname)
    assert_equal('Hofbecker', customer.lastname)

    post_comment = "Any updates yet? It's urgent. I love my hat."
    comment      = customer_client.put_comment(post['id'], post_comment)

    # fetch check system account
    Channel.fetch

    # check if second article has been created
    article = Ticket::Article.find_by(message_id: comment['id'])

    assert(article, "article comment '#{comment['id']}' imported")
    assert_equal(article.from, customer_name, 'ticket article inbound body')
    assert_equal(article.body, post_comment, 'ticket article inbound body')
    assert_equal(2, article.ticket.articles.count, 'ticket article inbound count')
    assert_equal(post_comment, article.ticket.articles.last.body, 'ticket article inbound body')
  end

  test 'f - feed post and comment reply' do

    customer_client = Koala::Facebook::API.new(customer_access_token)
    feed_post       = "I've got an issue with my hat, serial number ##{rand(99_999)}"
    post            = customer_client.put_wall_post(feed_post, {}, page_id)

    # fetch check system account
    Channel.fetch

    article = Ticket::Article.find_by(message_id: post['id'])
    ticket = article.ticket
    assert(article, "article post '#{post['id']}' imported")

    # check customer
    customer = ticket.customer
    assert_equal('Bernd', customer.firstname)
    assert_equal('Hofbecker', customer.lastname)

    # reply via ticket
    reply_text = "What's your issue Bernd?"
    outbound_article = Ticket::Article.create(
      ticket_id:     ticket.id,
      body:          reply_text,
      in_reply_to:   post['id'],
      type:          Ticket::Article::Type.find_by(name: 'facebook feed comment'),
      sender:        Ticket::Article::Sender.find_by(name: 'Agent'),
      internal:      false,
      updated_by_id: 1,
      created_by_id: 1,
    )
    assert(outbound_article, 'outbound article created')
    assert_equal(outbound_article.from, 'Hansi Merkurs Hutfabrik', 'ticket article outbound count')
    assert_equal(outbound_article.ticket.articles.count, 2, 'ticket article outbound count')

    post_comment = 'The peacock feather is fallen off.'
    comment      = customer_client.put_comment(post['id'], post_comment)

    # fetch check system account
    Channel.fetch

    article = Ticket::Article.find_by(message_id: comment['id'])
    assert(article, "article comment '#{comment['id']}' imported")

    # reply via ticket
    reply_text = "Please send it to our address and add the ticket number #{article.ticket.number}."
    outbound_article = Ticket::Article.create(
      ticket_id:     ticket.id,
      body:          reply_text,
      in_reply_to:   comment['id'],
      type:          Ticket::Article::Type.find_by(name: 'facebook feed comment'),
      sender:        Ticket::Article::Sender.find_by(name: 'Agent'),
      internal:      false,
      updated_by_id: 1,
      created_by_id: 1,
    )
    assert(outbound_article, 'outbound article created')
    assert_equal(outbound_article.from, 'Hansi Merkurs Hutfabrik', 'ticket article outbound count')
    assert_equal(outbound_article.ticket.articles.count, 4, 'ticket article outbound count')
  end

end
