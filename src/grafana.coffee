# Description:
#   Query Grafana dashboards
#
#   Examples:
#   - `hubot graf db graphite-carbon-metrics` - Get all panels in the dashboard
#   - `hubot graf db graphite-carbon-metrics:3` - Get only the third panel of a particular dashboard
#   - `hubot graf db graphite-carbon-metrics:cpu` - Get only the panels containing "cpu" (case insensitive) in the title
#   - `hubot graf db graphite-carbon-metrics now-12hr` - Get a dashboard with a window of 12 hours ago to now
#   - `hubot graf db graphite-carbon-metrics now-24hr now-12hr` - Get a dashboard with a window of 24 hours ago to 12 hours ago
#   - `hubot graf db graphite-carbon-metrics:3 now-8d now-1d` - Get only the third panel of a particular dashboard with a window of 8 days ago to yesterday
#
# Configuration:
#   HUBOT_GRAFANA_HOST - Host for your Grafana 2.0 install, e.g. 'http://play.grafana.org'
#   HUBOT_GRAFANA_API_KEY - API key for a particular user (leave unset if unauthenticated)
#   HUBOT_GRAFANA_S3_BUCKET - Optional; Name of the S3 bucket to copy the graph into
#   HUBOT_GRAFANA_S3_ACCESS_KEY_ID - Optional; Access key ID for S3
#   HUBOT_GRAFANA_S3_SECRET_ACCESS_KEY - Optional; Secret access key for S3
#   HUBOT_GRAFANA_S3_PREFIX - Optional; Bucket prefix (useful for shared buckets)
#   HUBOT_GRAFANA_S3_REGION - Optional; Bucket region (defaults to us-standard)
#   HUBOT_USE_GRAFANA_IMAGES - true|false, whether to use grafana-images
#   HUBOT_GRAFANA_IMAGES_HOST - The host where grafana images resides, e.g. 'http://grafana.example.com'
#
# Dependencies:
#   "knox": "^0.9.2"
#   "request": "~2"
#
# Commands:
#   hubot graf db <dashboard slug>[:<panel id>][ <template variables>][ <from clause>][ <to clause>] - Show grafana dashboard graphs
#   hubot graf list - Lists all dashboards available
#

crypto  = require 'crypto'
knox    = require 'knox'
request = require 'request'

module.exports = (robot) ->
  # Various configuration options stored in environment variables
  grafana_host = process.env.HUBOT_GRAFANA_HOST
  grafana_api_key = process.env.HUBOT_GRAFANA_API_KEY
  s3_bucket = process.env.HUBOT_GRAFANA_S3_BUCKET
  s3_access_key = process.env.HUBOT_GRAFANA_S3_ACCESS_KEY_ID
  s3_secret_key = process.env.HUBOT_GRAFANA_S3_SECRET_ACCESS_KEY
  s3_prefix = process.env.HUBOT_GRAFANA_S3_PREFIX
  s3_region = 'us-standard'
  s3_region = process.env.HUBOT_GRAFANA_S3_REGION if process.env.HUBOT_GRAFANA_S3_REGION
  use_grafana_images = process.env.HUBOT_USE_GRAFANA_IMAGES
  grafana_images_host = if process.env.HUBOT_GRAFANA_IMAGES_HOST then process.env.HUBOT_GRAFANA_IMAGES_HOST else grafana_host

  # Get a specific dashboard with options
  robot.respond /(?:grafana|graph|graf) (?:dash|dashboard|db) ([A-Za-z0-9\-\:_]+)(.*)?/i, (msg) ->
    slug = msg.match[1].trim()
    remainder = msg.match[2]
    timespan = {
      from: 'now-6h'
      to: 'now'
    }
    variables = ''
    pid = false
    pname = false

    # Parse out a specific panel
    if /\:/.test slug
      parts = slug.split(':')
      slug = parts[0]
      pid = parseInt parts[1], 10
      if isNaN pid
        pid = false
        pname = parts[1].toLowerCase()

    # Check if we have any extra fields
    if remainder
      # The order we apply non-variables in
      timeFields = ['from', 'to']

      for part in remainder.trim().split ' '
        # Check if it's a variable or part of the timespan
        if part.indexOf('=') >= 0
          variables = "#{variables}&var-#{part}"

        # Only add to the timespan if we haven't already filled out from and to
        else if timeFields.length > 0
          timespan[timeFields.shift()] = part.trim()

    robot.logger.debug msg.match
    robot.logger.debug slug
    robot.logger.debug timespan
    robot.logger.debug variables
    robot.logger.debug pid
    robot.logger.debug pname

    # Call the API to get information about this dashboard
    callGrafana "dashboards/db/#{slug}", (dashboard) ->
      robot.logger.debug dashboard

      # Check dashboard information
      if !dashboard
        return sendError 'An error ocurred. Check your logs for more details.', msg
      if dashboard.message
        return sendError dashboard.message, msg

      # Handle refactor done for version 2.0.2+
      if dashboard.dashboard
        # 2.0.2+: Changed in https://github.com/grafana/grafana/commit/e5c11691203fe68958e66693e429f6f5a3c77200
        data = dashboard.dashboard
        # The URL was changed in https://github.com/grafana/grafana/commit/35cc0a1cc0bca453ce789056f6fbd2fcb13f74cb
        apiEndpoint = 'dashboard-solo'
      else
        # 2.0.2 and older
        data = dashboard.model
        apiEndpoint = 'dashboard/solo'

      # Support for templated dashboards
      robot.logger.debug data.templating.list
      if data.templating.list
        template_map = []
        for template in data.templating.list
          template_map['$' + template.name] = template.current.text

      # Return dashboard rows
      panelNumber = 0
      for row in data.rows
        for panel in row.panels
          robot.logger.debug panel

          panelNumber += 1

          # Skip if panel ID was specified and didn't match
          if pid && pid != panelNumber
            continue

          # Skip if panel name was specified any didn't match
          if pname && panel.title.toLowerCase().indexOf(pname) is -1
            continue

          # Build links for message sending
          title = formatTitleWithTemplate(panel.title, template_map)
          imageUrl = "#{grafana_host}/render/#{apiEndpoint}/db/#{slug}/?panelId=#{panel.id}&width=1000&height=500&from=#{timespan.from}&to=#{timespan.to}#{variables}"
          link = "#{grafana_host}/dashboard/db/#{slug}/?panelId=#{panel.id}&fullscreen&from=#{timespan.from}&to=#{timespan.to}#{variables}"

          # Fork here for S3-based upload and non-S3
          if (s3_bucket && s3_access_key && s3_secret_key)
            s3FetchAndUpload msg, title, imageUrl, link
          else if (use_grafana_images == "true")
            customFetchAndUpload msg, title, imageUrl, link
          else
            sendRobotResponse msg, title, imageUrl, link

  # Get a list of available dashboards
  robot.respond /(?:grafana|graph|graf) list$/i, (msg) ->
    callGrafana 'search', (dashboards) ->
      robot.logger.debug dashboards
      response = "Available dashboards:\n"

      # Handle refactor done for version 2.0.2+
      if dashboards.dashboards
        list = dashboards.dashboards
      else
        list = dashboards

      robot.logger.debug list

      for dashboard in list
        # Handle refactor done for version 2.0.2+
        if dashboard.uri
          slug = dashboard.uri.replace /^db\//, ''
        else
          slug = dashboard.slug
        response = response + "- #{slug}: #{dashboard.title}\n"

      # Remove trailing newline
      response.trim()

      msg.send response

  # Show help text
  robot.respond /(?:grafana|graph|graf) help$/i, (msg) ->
    response = "grafana usage:\n"
    response += "  hubot graf list\n"
    response += "  hubot graf db cm-monitoring-default\n"
    response += "  hubot graf db cm-monitoring-default:8\n"
    response += "  hubot graf db cm-monitoring-default:swap\n"
    response += "  hubot graf db cm-monitoring-default now-12hr\n"
    response += "  hubot graf db cm-monitoring-default now-24hr now-12hr\n"
    response += "  hubot graf db cm-monitoring-default:8 now-8d now-1d\n"
    response += "  hubot graf db cm-monitoring-default:swap server=ncv-dashing now-1w\n"
    msg.send response

  # Handle generic errors
  sendError = (message, msg) ->
    robot.logger.error message
    msg.send message

  # Format the title with template vars
  formatTitleWithTemplate = (title, template_map) ->
    title.replace /\$\w+/g, (match) ->
      if template_map[match]
        return template_map[match]
      else
        return match

  # Send robot response
  sendRobotResponse = (msg, title, image, link) ->
    msg.send "#{title}: #{image} - #{link}"

  # Call off to Grafana
  callGrafana = (url, callback) ->
    if grafana_api_key
      authHeader = {
        'Accept': 'application/json',
        'Authorization': "Bearer #{grafana_api_key}"
      }
    else
      authHeader = {
        'Accept': 'application/json'
      }
    robot.http("#{grafana_host}/api/#{url}").headers(authHeader).get() (err, res, body) ->
      if (err)
        robot.logger.error err
        return callback(false)
      data = JSON.parse(body)
      return callback(data)

  customFetchAndUpload = (msg, title, url, link) ->
    requestHeaders = {
      encoding: "utf8",
      Authorization: "Bearer #{grafana_api_key}",
      Accept: "application/json"
    }

    req_opts = {
      method: "POST",
      url: "#{grafana_images_host}/grafana-images",
      headers: requestHeaders,
      json: {
        imageUrl: url
      }
    }

    # post to grafana-images
    request req_opts, (err, res, json) ->
      robot.logger.debug "grafana-images POST: #{req_opts.url}, content-type[#{res.headers['content-type']}]"

      if res.statusCode == 200
        sendRobotResponse msg, title, json.pubImg, link
      else
        robot.logger.debug res
        robot.logger.error "Upload Error Code: #{res.statusCode}"
        msg.send "#{title} - [Access Error] - #{link}"

  # Pick a random filename
  s3UploadPath = () ->
    prefix = s3_prefix || 'grafana'
    "#{prefix}/#{crypto.randomBytes(20).toString('hex')}.png"

  # Fetch an image from provided URL, upload it to S3, returning the resulting URL
  s3FetchAndUpload = (msg, title, url, link) ->
    if grafana_api_key
        requestHeaders =
          encoding: null,
          auth:
            bearer: grafana_api_key
      else
        requestHeaders =
          encoding: null

    request url, requestHeaders, (err, res, body) ->
      robot.logger.debug "Uploading file: #{body.length} bytes, content-type[#{res.headers['content-type']}]"
      uploadToS3(msg, title, link, body, body.length, res.headers['content-type'])

  # Upload image to S3
  uploadToS3 = (msg, title, link, content, length, content_type) ->
    client = knox.createClient {
      key    : s3_access_key
      secret : s3_secret_key,
      bucket : s3_bucket,
      region : s3_region
    }

    headers = {
      'Content-Length' : length,
      'Content-Type'   : content_type,
      'x-amz-acl'      : 'public-read',
      'encoding'       : null
    }

    filename = s3UploadPath()

    req = client.put(filename, headers)
    req.on 'response', (res) ->
      if (200 == res.statusCode)
        sendRobotResponse msg, title, client.https(filename), link
      else
        robot.logger.debug res
        robot.logger.error "Upload Error Code: #{res.statusCode}"
        msg.send "#{title} - [Upload Error] - #{link}"
    req.end(content);
