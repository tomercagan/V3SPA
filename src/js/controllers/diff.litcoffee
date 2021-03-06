    vespaControllers = angular.module('vespaControllers')

    vespaControllers.controller 'diffCtrl', ($scope, VespaLogger, WSUtils,
        IDEBackend, $timeout, $modal, PositionManager, RefPolicy, $q, SockJSService) ->

      comparisonPolicy = null
      comparisonRules = []
      comparisonNodes = []
      comparisonLinks = []
      comparisonNodeMap = {}
      comparisonLinkMap = {}
      comparisonLinkSourceMap = {}
      comparisonLinkTargetMap = {}
      comparison =
        original:
          nodes: []
          links: []
      $scope.input = 
        refpolicy: comparisonPolicy

      # The 'outstanding' attribute is truthy when a policy is being loaded
      $scope.status = SockJSService.status

      $scope.controls =
        showModulesSelect: false
        tab: 'nodesTab'
        linksVisible: false
        links:
          primary: true
          both: true
          comparison: true

      $scope.$watch 'controls.links', ((value) -> if value then redraw()), true
      $scope.$watch 'controls.linksVisible', ((value) -> if value == false or value == true then redraw())

      comparisonPolicyId = () ->
        if comparisonPolicy then comparisonPolicy.id else ""

      primaryPolicyId = () ->
        if IDEBackend.current_policy then IDEBackend.current_policy.id else ""

Get the raw JSON

      fetch_raw = ->

        deferred = $q.defer()

        WSUtils.fetch_raw_graph(comparisonPolicy._id).then (json) =>
          comparisonRules = []
          comparison.original.nodes = json.parameterized.raw.nodes
          comparison.original.links = json.parameterized.raw.links
          comparisonNodes = json.parameterized.raw.nodes
          comparisonLinks = json.parameterized.raw.links

          deferred.resolve()

        return deferred.promise

Fetch the policy info (refpolicy) needed to get the raw JSON

      load_refpolicy = (id)->
        if comparisonPolicy? and comparisonPolicy.id == id
          return

        deferred = @_deferred_load || $q.defer()

        req = 
          domain: 'refpolicy'
          request: 'get'
          payload: id

        SockJSService.send req, (data)=>
          if data.error?
            comparisonPolicy = null
            deferred.reject(comparisonPolicy)
          else
            comparisonPolicy = data.payload
            comparisonPolicy._id = comparisonPolicy._id.$oid

            deferred.resolve(comparisonPolicy)

        return deferred.promise
      
Enumerate the differences between the two policies

      find_differences = () =>
        graph.links.length = 0

        primaryNodes = $scope.primaryNodes
        primaryLinks = $scope.primaryLinks
        primaryNodeMap = $scope.nodeMap
        primaryLinkMap = $scope.linkMap

        # Reset the "selected" flag when changing policies
        primaryNodes.forEach (n) -> n.selected = true
        comparisonNodes.forEach (n) -> n.selected = true

        # Reconcile the two lists of links
        # Loop over the primary links: if in comparison links
        # - change "policy" to "both"
        # - remove from comparisonLinkMap
        primaryLinks.forEach (link) ->
          comparisonLink = comparisonLinkMap["#{link.source.type}-#{link.source.name}-#{link.target.type}-#{link.target.name}"]
          if comparisonLink
            link.policy = "both"
            delete comparisonLinkMap["#{link.source.type}-#{link.source.name}-#{link.target.type}-#{link.target.name}"]

        comparisonLinks = d3.values(comparisonLinkMap)
        graph.links = comparisonLinks.concat(primaryLinks)

        # Reconcile the two lists of nodes
        # Loop over the primary nodes: if in comparison nodes
        # - change "policy" to "both"
        # - set it to unselected
        # - copy over its links to the primary node
        # - remove from comparisonNodeMap
        primaryNodes.forEach (node) ->
          comparisonNode = comparisonNodeMap["#{node.type}-#{node.name}"]
          if comparisonNode
            node.policy = "both"
            node.selected = false
            # Filter out duplicate links we already deleted
            node.links = node.links.concat(comparisonNode.links.filter((l) ->
              return comparisonLinkMap["#{l.source.type}-#{l.source.name}-#{l.target.type}-#{l.target.name}"]))
            delete comparisonNodeMap["#{node.type}-#{node.name}"]

            # Rewire the links to use the "both" node instead of comparisonNode
            if comparisonLinkSourceMap["#{comparisonNode.type}-#{comparisonNode.name}"]
              comparisonLinkSourceMap["#{comparisonNode.type}-#{comparisonNode.name}"].forEach (l) ->
                l.source = node
            if comparisonLinkTargetMap["#{comparisonNode.type}-#{comparisonNode.name}"]
              comparisonLinkTargetMap["#{comparisonNode.type}-#{comparisonNode.name}"].forEach (l) ->
                l.target = node

        comparisonNodes = d3.values comparisonNodeMap

        # Remove any duplicate links we may have generated by rewiring the links
        # TODO: Probably not any duplicates. Verify whether there can be, and remove code if not.
        graph.links = _.uniqBy(graph.links, (l) ->
          return "#{l.source.type}-#{l.source.name}-#{l.target.type}-#{l.target.name}")

        graph.allNodes = primaryNodes.concat comparisonNodes

        graph.subjNodes = []
        graph.objNodes = []
        graph.classNodes = []
        graph.permNodes = []

        graph.allNodes.forEach (n) ->
          if n.type == "subject"
            graph.subjNodes.push n
          else if n.type == "object"
            graph.objNodes.push n
          else if n.type == "class"
            graph.classNodes.push n
          else #perm
            graph.permNodes.push n
        
      $scope.selectionChange = () ->
        redraw()

      $scope.load = ->
        load_refpolicy($scope.input.refpolicy.id).then(fetch_raw).then(update)

      $scope.list_refpolicies = 
        query: (query)->
          promise = RefPolicy.list()
          promise.then(
            (policy_list)->
              dropdown = 
                results:  for d in policy_list
                  id: d._id.$oid
                  text: d.id
                  data: d

              query.callback(dropdown)
          )

      width = 350
      height = 500
      padding = 50
      radius = 5
      graph =
        links: []
        subjNodes: []
        objNodes: []
        classNodes: []
        permNodes: []
        allNodes: []
      $scope.graph = graph
      color = d3.scale.category10()
      svg = d3.select("svg.diffview").select("g.viewer")
      subjSvg = svg.select("g.subjects").attr("transform", "translate(0,0)")
      permSvg = svg.select("g.permissions").attr("transform", "translate(#{width+padding},0)")
      objSvg = svg.select("g.objects").attr("transform", "translate(#{2*(width+padding)},-#{height/2})")
      classSvg = svg.select("g.classes").attr("transform", "translate(#{3*(width+padding)},0)")

      subjSvg.append("rect")
        .attr("width", width + 16)
        .attr("height", height + 16)
        .attr("x", -8)
        .attr("y", -8)
        .attr("style", "fill:rgba(200,200,200,0.15)")
      objSvg.append("rect")
        .attr("width", width + 16)
        .attr("height", height + 16)
        .attr("x", -8)
        .attr("y", -8)
        .attr("style", "fill:rgba(200,200,200,0.15)")
      classSvg.append("rect")
        .attr("width", width + 16)
        .attr("height", height + 16)
        .attr("x", -8)
        .attr("y", -8)
        .attr("style", "fill:rgba(200,200,200,0.15)")
      permSvg.append("rect")
        .attr("width", width + 16)
        .attr("height", height + 16)
        .attr("x", -8)
        .attr("y", -8)
        .attr("style", "fill:rgba(200,200,200,0.15)")

      linkScale = d3.scale.linear()
        .range([1,2*radius])

      gridLayout = d3.layout.grid()
        .points()
        .size([width, height])

      textStyle =
        'text-anchor': "middle"
        'fill': "#ccc"
        'font-size': "56px"
      svg.select("g.labels").append("text")
        .attr "x", width / 2
        .attr "y", height / 2
        .style textStyle
        .text "subjects"
      svg.select("g.labels").append("text")
        .attr "x", (width + padding) + width / 2
        .attr "y", height / 2
        .style textStyle
        .text "permissions"
      svg.select("g.labels").append("text")
        .attr "x", 2 * (width + padding) + width / 2
        .attr "y", 0
        .style textStyle
        .text "objects"
      svg.select("g.labels").append("text")
        .attr "x", 3 * (width + padding) + width / 2
        .attr "y", height / 2
        .style textStyle
        .text "classes"

      nodeExpand = (show, type, clickedNodeData) ->
        # If a node is associated with this on, and has the given type, set the selected attr
        l = -1
        while ++l < clickedNodeData.links.length
          if clickedNodeData.links[l].source.type == type
            clickedNodeData.links[l].source.selected = show
          if clickedNodeData.links[l].target.type == type
            clickedNodeData.links[l].target.selected = show

      $scope.update_view = (data) ->
        $scope.policy = IDEBackend.current_policy

        if $scope.policy?.json?.parameterized?.raw?
          $scope.primaryNodes = $scope.policy.json.parameterized.raw.nodes
          $scope.primaryLinks = $scope.policy.json.parameterized.raw.links

        update()

      update = () ->
        $scope.policyIds =
          primary: primaryPolicyId()
          both: if comparisonPolicyId() then "both" else undefined
          comparison: comparisonPolicyId() || undefined

        if not $scope.primaryNodes?.length or
        not $scope.primaryLinks?.length or
        not comparison?.original?.nodes?.length or
        not comparison?.original?.links?.length
          return

        nodeMapReducer = (map, currNode) ->
          map["#{currNode.type}-#{currNode.name}"] = currNode
          return map

        linkMapReducer = (map, currLink) ->
          map["#{currLink.source.type}-#{currLink.source.name}-#{currLink.target.type}-#{currLink.target.name}"] = currLink
          return map

        addPolicy = (policyId) ->
          return (item) ->
            item.policy = policyId

        nodeMapKey = (link) -> "#{link.source.type}-#{link.source.name}-#{link.target.type}-#{link.target.name}"

        # Need shallow copies of the nodes and links arrays
        $scope.primaryNodes = $scope.primaryNodes.slice()
        $scope.primaryLinks = $scope.primaryLinks.slice()
        $scope.primaryNodes.forEach addPolicy(primaryPolicyId())
        $scope.primaryLinks.forEach addPolicy(primaryPolicyId())
        comparisonNodes = comparison.original.nodes.slice()
        comparisonLinks = comparison.original.links.slice()
        comparisonNodes.forEach addPolicy(comparisonPolicyId())
        comparisonLinks.forEach addPolicy(comparisonPolicyId())


        # Convert the nodes and links arrays into maps
        $scope.nodeMap = $scope.primaryNodes.reduce nodeMapReducer, {}
        $scope.linkMap = $scope.primaryLinks.reduce linkMapReducer, {}
        comparisonNodeMap = comparisonNodes.reduce nodeMapReducer, {}
        comparisonLinkMap = comparisonLinks.reduce linkMapReducer, {}
        comparisonLinkSourceMap = comparisonLinks.reduce((map, currLink)->
          map["#{currLink.source.type}-#{currLink.source.name}"] = map["#{currLink.source.type}-#{currLink.source.name}"] or []
          map["#{currLink.source.type}-#{currLink.source.name}"].push currLink
          return map
        , {})
        comparisonLinkTargetMap = comparisonLinks.reduce((map, currLink)->
          map["#{currLink.target.type}-#{currLink.target.name}"] = map["#{currLink.target.type}-#{currLink.target.name}"] or []
          map["#{currLink.target.type}-#{currLink.target.name}"].push currLink
          return map
        , {})

        find_differences()

        $scope.clickedNode = null
        $scope.clickedNodeRules = []

        if $scope.policyIds.primary and $scope.policyIds.comparison
          redraw()

      redraw = () ->
        [
          {nodes: graph.subjNodes, svg: subjSvg},
          {nodes: graph.objNodes, svg: objSvg},
          {nodes: graph.permNodes, svg: permSvg},
          {nodes: graph.classNodes, svg: classSvg}
        ].forEach (tuple) ->
          getConnected = (d) ->
            linksToShow = d.links

            linksToShow = linksToShow.filter (l) -> return l.source.selected && l.target.selected

            uniqNodes = linksToShow.reduce((prev, l) ->
              prev.push l.source
              prev.push l.target
              return prev
            , [])

            # No links to show, so make sure we highlight the node the user moused over
            if uniqNodes.length == 0
              uniqNodes.push d

            uniqNodes = _.uniq uniqNodes

            return [uniqNodes, linksToShow]

          nodeMouseover = (d) ->
            [uniqNodes, linksToShow] = getConnected(d)

            d3.selectAll uniqNodes.map((n) -> return "g.node." + CSS.escape("t-#{n.type}-#{n.name}")).join(",")
              .classed "highlight", true
              .each () -> @.parentNode.appendChild(@)

            # No links to show, so return
            if linksToShow.length == 0
              return

            d3.selectAll linksToShow.map((link) -> "." + CSS.escape("l-#{link.source.type}-#{link.source.name}-#{link.target.type}-#{link.target.name}")).join ","
              .classed "highlight", true
              .each () -> @.parentNode.appendChild(@)

          nodeMouseout = (d) ->
            link.classed "highlight", false
            d3.selectAll "g.node.highlight"
              .classed "highlight", false

          nodeClick = (clickedNode) =>
            [uniqNodes, linksToShow] = getConnected(clickedNode)
            clicked = !clickedNode.clicked

            if clicked
              $scope.clickedNode = clickedNode
              $scope.clickedNodeRules = []

              reqParams = {}

              deferred = $q.defer()

              reqParams[clickedNode.type] = clickedNode.name

              req = 
                domain: 'raw'
                request: 'fetch_rules'
                payload:
                  policy: [IDEBackend.current_policy._id, comparisonPolicy._id]
                  params: reqParams

              SockJSService.send req, (result)=>
                if result.error?
                  $scope.clickedNodeRules = []
                else
                  rules = JSON.parse(result.payload)
                  $scope.clickedNodeRules = rules.sort (a,b) ->
                    if a.policy != b.policy then return a.policy - b.policy
                    return a.rule - b.rule
                if !$scope.$$phase then $scope.$apply()

            else
              $scope.clickedNode = null
              $scope.clickedNodeRules = []
              if !$scope.$$phase then $scope.$apply()

            changedNodes = graph.allNodes.filter (n) -> return n.clicked
            changedLinks = graph.links.filter (l) -> return l.source.clicked && l.target.clicked
            changedLinks = changedLinks.concat linksToShow

            # Set clicked = false on all nodes
            graph.subjNodes.forEach (d) -> d.clicked = false
            graph.objNodes.forEach (d) -> d.clicked = false
            graph.classNodes.forEach (d) -> d.clicked = false
            graph.permNodes.forEach (d) -> d.clicked = false

            # Toggle clicked
            uniqNodes.forEach (d) -> d.clicked = clicked

            changedNodes = changedNodes.concat uniqNodes

            # For all nodes with clicked == true, add the "clicked" class
            d3.selectAll _.uniq(changedNodes.map((n) -> return "g.node." + CSS.escape("t-#{n.type}-#{n.name}"))).join(",")
              .classed "clicked", (d) -> d.clicked
              .each () -> @.parentNode.appendChild(@)

            # No links to show, so return
            if changedLinks.length == 0
              return

            d3.selectAll changedLinks.map((link) -> "." + CSS.escape("l-#{link.source.type}-#{link.source.name}-#{link.target.type}-#{link.target.name}")).join ","
              .classed "clicked", (d) -> d.source.clicked && d.target.clicked

          # Sort first by policy, then by name
          tuple.nodes.sort (a,b) ->
            if (a.policy == primaryPolicyId() && a.policy != b.policy) || (a.policy == "both" && b.policy == comparisonPolicyId())
              return -1
            else if a.policy == b.policy
              return if a.name == b.name then 0 else if a.name < b.name then return -1 else return 1
            else
              return 1

          node = tuple.svg.selectAll ".node"
          
          # Clear the old nodes and redraw everything
          node.remove()

          node = tuple.svg.selectAll ".node"
            .data gridLayout(tuple.nodes.filter (d) -> return d.selected)
            .attr "class", (d) -> "node t-#{d.type}-#{d.name}"
            .classed "clicked", (d) -> d.clicked

          nodeEnter = node.enter().append "g"
            .attr "class", (d) -> "node t-#{d.type}-#{d.name}"
            .attr "transform", (d) -> return "translate(#{d.x},#{d.y})"
            .classed "clicked", (d) -> d.clicked

          nodeEnter.append "text"
            .attr "class", (d) -> "node-label t-#{d.type}-#{d.name}"
            .attr "x", 0
            .attr "y", "-5px"
            .text (d) -> d.name

          nodeEnter.append "circle"
            .attr "r", radius
            .attr "cx", 0
            .attr "cy", 0
            .attr "class", (d) ->
              if d.policy == primaryPolicyId()
                return "diff-left"
              else if d.policy == comparisonPolicyId()
                return "diff-right"
            .on "mouseover", nodeMouseover
            .on "mouseout", nodeMouseout
            .on "click", nodeClick

          node.exit().remove()

        genContextItems = (data) ->
          menuItems = {}
          if data.type != 'subject'
            menuItems['show-subject'] =
              label: 'Show connected subjects'
              callback: ->
                nodeExpand(true, 'subject', data)
                redraw()
            menuItems['hide-subject'] =
              label: 'Hide connected subjects'
              callback: ->
                nodeExpand(false, 'subject', data)
                redraw()
          if data.type != 'object'
            menuItems['show-object'] =
              label: 'Show connected objects'
              callback: ->
                nodeExpand(true, 'object', data)
                redraw()
            menuItems['hide-object'] =
              label: 'Hide connected objects'
              callback: ->
                nodeExpand(false, 'object', data)
                redraw()
          if data.type != 'perm'
            menuItems['show-permission'] =
              label: 'Show connected permissions'
              callback: ->
                nodeExpand(true, 'perm', data)
                redraw()
            menuItems['hide-permission'] =
              label: 'Hide connected permissions'
              callback: ->
                nodeExpand(false, 'perm', data)
                redraw()
          if data.type != 'class'
            menuItems['show-class'] =
              label: 'Show connected classes'
              callback: ->
                nodeExpand(true, 'class', data)
                redraw()
            menuItems['hide-class'] =
              label: 'Hide connected classes'
              callback: ->
                nodeExpand(false, 'class', data)
                redraw()
          return menuItems

        d3.selectAll('.node circle').each (d) ->
            context_items = genContextItems(d)
            $(this).contextmenu
              target: '#diff-context-menu'
              items: context_items

        link = svg.select("g.links").selectAll ".link"

        # Clear the old links and redraw everything
        link.remove()

        link = svg.select("g.links").selectAll ".link"
          .data graph.links.filter((d) ->
            policyFilter = true
            for type,id of $scope.policyIds
              if id == d.policy then policyFilter = $scope.controls.links[type]
            return d.source.selected && d.target.selected && policyFilter
          ), (d,i) -> return "#{d.source.type}-#{d.source.name}-#{d.target.type}-#{d.target.name}"

        link.enter().append "line"
          .attr "class", (d) -> "link l-#{d.source.type}-#{d.source.name}-#{d.target.type}-#{d.target.name}"
          .style "stroke-width", (d) -> 1
          .attr "x1", (d) ->
            offset = 0
            if d.source.type == "perm"
              offset = width + padding
            else if d.source.type == "object"
              offset = 2 * (width + padding)
            return d.source.x + offset
          .attr "y1", (d) -> return d.source.y - if d.source.type == "object" then height/2 else 0
          .attr "x2", (d) ->
            offset = width + padding
            if d.target.type == "object"
              offset = 2 * (width + padding)
            else if d.target.type == "class"
              offset = 3 * (width + padding)
            return d.target.x + offset
          .attr "y2", (d) -> return d.target.y - if d.target.type == "object" then height/2 else 0
          .classed "clicked", (d) -> d.source.clicked && d.target.clicked
          .classed "visible", $scope.controls.linksVisible

        link.exit().remove()

Set up the viewport scroll

      positionMgr = PositionManager("tl.viewport::#{IDEBackend.current_policy._id}",
        {a: 0.7454701662063599, b: 0, c: 0, d: 0.7454701662063599, e: 200, f: 50}
      )

      svgPanZoom.init
        selector: '#surface svg.diffview'
        panEnabled: true
        zoomEnabled: true
        dragEnabled: false
        minZoom: 0.5
        maxZoom: 10
        onZoom: (scale, transform) ->
          positionMgr.update transform
        onPanComplete: (coords, transform) ->
          positionMgr.update transform

      $scope.$watch(
        () -> return (positionMgr.data)
        , 
        (newv, oldv) ->
          if not newv? or _.keys(newv).length == 0
            return
          g = svgPanZoom.getSVGViewport($("#surface svg.diffview")[0])
          svgPanZoom.set_transform(g, newv)
      )

      IDEBackend.add_hook "json_changed", $scope.update_view
      IDEBackend.add_hook "policy_load", IDEBackend.load_raw_graph
      
      $scope.$on "$destroy", ->
        IDEBackend.unhook "json_changed", $scope.update_view
        IDEBackend.unhook "policy_load", IDEBackend.load_raw_graph

      $scope.policy = IDEBackend.current_policy

      # Load the raw graph data if it is not loaded
      if $scope.policy?._id and not $scope.policy.json?.parameterized?.raw?
        IDEBackend.load_raw_graph()

      # If the graph data is already loaded, render the view
      if $scope.policy?.json?.parameterized?.raw?
        $scope.update_view()