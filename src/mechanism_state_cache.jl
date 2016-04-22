type MechanismStateCache{T}
    rootFrame::CartesianFrame3D
    transformsToParent::Dict{CartesianFrame3D, CacheElement{Transform3D{T}}}
    transformsToRoot::Dict{CartesianFrame3D, CacheElement{Transform3D{T}}}
    twistsWrtWorld::Dict{RigidBody, CacheElement{Twist{T}}}
    motionSubspaces::Dict{Joint, MutableCacheElement{GeometricJacobian{T}}}
    spatialInertias::Dict{RigidBody, MutableCacheElement{SpatialInertia{T}}}
    crbInertias::Dict{RigidBody, MutableCacheElement{SpatialInertia{T}}}

    function MechanismStateCache(rootFrame::CartesianFrame3D)
        transformsToParent = Dict{CartesianFrame3D, CacheElement{Transform3D{T}}}()
        transformsToRoot = Dict{CartesianFrame3D, CacheElement{Transform3D{T}}}()
        twistsWrtWorld = Dict{RigidBody, CacheElement{Twist{T}}}()
        motionSubspaces = Dict{Joint, MutableCacheElement{GeometricJacobian}}()
        spatialInertias = Dict{RigidBody, MutableCacheElement{SpatialInertia{T}}}()
        crbInertias = Dict{RigidBody, MutableCacheElement{SpatialInertia{T}}}()
        new(rootFrame, transformsToParent, transformsToRoot, twistsWrtWorld, motionSubspaces, spatialInertias, crbInertias)
    end
end

function setdirty!{T}(cache::MechanismStateCache{T})
    for element in values(cache.transformsToParent) setdirty!(element) end
    for element in values(cache.transformsToRoot) setdirty!(element) end
    for element in values(cache.twistsWrtWorld) setdirty!(element) end
    for element in values(cache.motionSubspaces) setdirty!(element) end
    for element in values(cache.spatialInertias) setdirty!(element) end
    for element in values(cache.crbInertias) setdirty!(element) end
end

function add_frame!{T}(cache::MechanismStateCache{T}, t::Transform3D{T})
    # for fixed frames
    to_parent = ImmutableCacheElement(t)
    parent_to_root = cache.transformsToRoot[t.to]
    cache.transformsToParent[t.from] = to_parent
    to_root = MutableCacheElement(() -> get(parent_to_root) * get(to_parent))
    cache.transformsToRoot[t.from] = to_root

    setdirty!(cache)
    return cache
end

function add_frame!{T}(cache::MechanismStateCache{T}, updateTransformToParent::Function)
    # for non-fixed frames
    to_parent = MutableCacheElement(updateTransformToParent)
    t = to_parent.data
    parent_to_root = cache.transformsToRoot[t.to]
    cache.transformsToParent[t.from] = to_parent
    to_root = MutableCacheElement(() -> get(parent_to_root) * get(to_parent))
    cache.transformsToRoot[t.from] = to_root

    setdirty!(cache)
    return cache
end

transform_to_parent(cache::MechanismStateCache, frame::CartesianFrame3D) = get(cache.transformsToParent[frame])
transform_to_root(cache::MechanismStateCache, frame::CartesianFrame3D) = get(cache.transformsToRoot[frame])
relative_transform(cache::MechanismStateCache, from::CartesianFrame3D, to::CartesianFrame3D) = inv(transform_to_root(cache, to)) * transform_to_root(cache, from)
twist_wrt_world(cache::MechanismStateCache, body::RigidBody) = get(cache.twistsWrtWorld[body])
relative_twist(cache::MechanismStateCache, body::RigidBody, base::RigidBody) = -get(cache.twistsWrtWorld[base]) + get(cache.twistsWrtWorld[body])
motion_subspace(cache::MechanismStateCache, joint::Joint) = get(cache.motionSubspaces[joint])
spatial_inertia(cache::MechanismStateCache, body::RigidBody) = get(cache.spatialInertias[body])
crb_inertia(cache::MechanismStateCache, body::RigidBody) = get(cache.crbInertias[body])

transform{T}(cache::MechanismStateCache{T}, point::Point3D{T}, to::CartesianFrame3D) = relative_transform(cache, point.frame, to) * point
transform{T}(cache::MechanismStateCache{T}, twist::Twist{T}, to::CartesianFrame3D) = transform(twist, relative_transform(cache, t.frame, to))

function MechanismStateCache{M, X}(m::Mechanism{M}, x::MechanismState{X})
    typealias T promote_type(M, X)
    rootBody = root(m)
    cache = MechanismStateCache{T}(rootBody.frame)

    rootTransform = ImmutableCacheElement(Transform3D{T}(rootBody.frame, rootBody.frame))
    cache.transformsToRoot[rootBody.frame] = rootTransform

    rootTwist = zero(Twist{T}, rootBody.frame, rootBody.frame, rootBody.frame)
    cache.twistsWrtWorld[rootBody] = ImmutableCacheElement(rootTwist)

    vertices = toposort(m.tree)
    for vertex in vertices
        body = vertex.vertexData
        if !isroot(vertex)
            parentBody = vertex.parent.vertexData
            joint = vertex.edgeToParentData

            qJoint = x.q[joint]
            vJoint = x.v[joint]

            # frames
            add_frame!(cache, m.jointToJointTransforms[joint])
            add_frame!(cache, () -> joint_transform(joint, qJoint))

            # twists
            transformToRootCache = cache.transformsToRoot[joint.frameAfter]
            parentTwistCache = cache.twistsWrtWorld[parentBody]
            updateTwistWrtWorld = () -> begin
                parentTwist = get(parentTwistCache)
                jointTwist = joint_twist(joint, qJoint, vJoint)
                jointTwist = Twist(joint.frameAfter, parentTwist.body, jointTwist.frame, jointTwist.angular, jointTwist.linear) # to make the frames line up;
                return parentTwist + transform(jointTwist, get(transformToRootCache))
            end
            cache.twistsWrtWorld[body] = MutableCacheElement(updateTwistWrtWorld)

            # motion subspaces
            updateMotionSubspace = () -> transform(motion_subspace(joint, qJoint), get(transformToRootCache))
            cache.motionSubspaces[joint] = MutableCacheElement(updateMotionSubspace)
        end

        # additional body fixed frames
        for transform in m.bodyFixedFrameDefinitions[body]
            add_frame!(cache, transform)
        end

        if !isroot(vertex)
            parentBody = vertex.parent.vertexData

            # inertias
            transformBodyToRootCache = cache.transformsToRoot[body.inertia.frame]
            updateSpatialInertia = () -> transform(body.inertia, get(transformBodyToRootCache))
            spatialInertiaCache = MutableCacheElement(updateSpatialInertia)
            cache.spatialInertias[body] = spatialInertiaCache

            # crb inertias
            if isroot(parentBody)
                updateCRBInertia = () -> get(spatialInertiaCache)
                cache.crbInertias[body] = MutableCacheElement(updateCRBInertia)
            else
                parentCRBInertia = cache.crbInertias[parentBody]
                updateCRBInertia = () -> get(parentCRBInertia) + get(spatialInertiaCache)
                cache.crbInertias[body] = MutableCacheElement(updateCRBInertia)
            end
        end
    end

    setdirty!(cache)
    return cache
end
