"""Style the deskctl GUI-built room, preserving the original .blend file.

Run in Blender's Python console using exec(compile(...)). No external assets.
Principled shader reference: https://docs.blender.org/api/main/bpy.types.ShaderNodeBsdfPrincipled.html
"""
import bpy
import math
import random
from pathlib import Path
from mathutils import Vector

ROOT = Path('/home/osmait/Projects/computer-use-hyperland')
random.seed(19)
scene = bpy.context.scene
assert '01 Suelo' in bpy.data.objects, 'Open the deskctl room first'

# Only remove generated objects when rerunning this styling pass.
for ob in list(bpy.data.objects):
    if ob.get('deskctl_style'):
        bpy.data.objects.remove(ob, do_unlink=True)

def tag(ob):
    ob['deskctl_style'] = True
    return ob

def mat(name, color, rough=.6, metal=0, texture=None):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    m.diffuse_color = (*color, 1)
    n = m.node_tree.nodes
    l = m.node_tree.links
    p = n.get('Principled BSDF')
    p.inputs['Base Color'].default_value = (*color, 1)
    p.inputs['Roughness'].default_value = rough
    p.inputs['Metallic'].default_value = metal
    if texture:
        tex = n.new('ShaderNodeTexNoise')
        tex.inputs['Scale'].default_value = 5 if texture == 'wood' else 150
        tex.inputs['Detail'].default_value = 3
        coord = n.new('ShaderNodeTexCoord')
        mapping = n.new('ShaderNodeVectorMath')
        mapping.operation = 'MULTIPLY'
        mapping.inputs[1].default_value = (1, 35, 4) if texture == 'wood' else (1, 1, 1)
        l.new(coord.outputs['Generated'], mapping.inputs[0])
        l.new(mapping.outputs[0], tex.inputs['Vector'])
        ramp = n.new('ShaderNodeValToRGB')
        ramp.color_ramp.elements[0].position = .18
        ramp.color_ramp.elements[0].color = (*(v * .65 for v in color), 1)
        ramp.color_ramp.elements[1].position = .82
        ramp.color_ramp.elements[1].color = (*(min(v * 1.16, 1) for v in color), 1)
        l.new(tex.outputs['Fac'], ramp.inputs[0])
        l.new(ramp.outputs['Color'], p.inputs['Base Color'])
        bump = n.new('ShaderNodeBump')
        bump.inputs['Strength'].default_value = .17 if texture == 'wood' else .25
        bump.inputs['Distance'].default_value = .018 if texture == 'wood' else .008
        l.new(tex.outputs['Fac'], bump.inputs['Height'])
        l.new(bump.outputs[0], p.inputs['Normal'])
        if texture == 'fabric':
            p.inputs['Sheen Weight'].default_value = .3
    return m

oak = mat('Roble natural | veta', (.46, .29, .14), .48, texture='wood')
cream = mat('Estuco calido', (.72, .68, .58), .88, texture='plaster')
sage = mat('Lino salvia', (.19, .28, .19), .88, texture='fabric')
ivory = mat('Algodon marfil', (.79, .76, .66), .9, texture='fabric')
terracotta = mat('Ceramica arcilla', (.39, .13, .07), .72)
black = mat('Metal grafito', (.027, .034, .03), .35, .65)
brass = mat('Laton cepillado', (.5, .3, .1), .32, .75)
rugmat = mat('Alfombra boucle', (.54, .43, .29), .96, texture='fabric')
paper = mat('Papel hueso', (.8, .75, .62), .92)
leafmat = mat('Hojas verde profundo', (.045, .15, .052), .4)
soil = mat('Tierra', (.04, .022, .011), 1)

def assign(ob, material):
    ob.data.materials.clear()
    ob.data.materials.append(material)

def cube(name, loc, dims, material, bevel=.025):
    bpy.ops.mesh.primitive_cube_add(size=1, location=loc)
    ob = tag(bpy.context.object)
    ob.name = name
    ob.dimensions = dims
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    assign(ob, material)
    if bevel:
        mod = ob.modifiers.new('Bordes artesanales', 'BEVEL')
        mod.width = bevel
        mod.segments = 3
        mod = ob.modifiers.new('Normales', 'WEIGHTED_NORMAL')
    return ob

def sphere(name, loc, scale, material):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=32, ring_count=16, location=loc)
    ob = tag(bpy.context.object)
    ob.name = name
    ob.scale = scale
    assign(ob, material)
    for p in ob.data.polygons:
        p.use_smooth = True
    return ob

def cylinder(name, loc, radius, depth, material, r2=None):
    bpy.ops.mesh.primitive_cone_add(vertices=64, radius1=radius,
        radius2=radius if r2 is None else r2, depth=depth, location=loc)
    ob = tag(bpy.context.object)
    ob.name = name
    assign(ob, material)
    be = ob.modifiers.new('Cantos suaves', 'BEVEL')
    be.width = .012
    be.segments = 3
    for p in ob.data.polygons:
        p.use_smooth = True
    return ob

def rod(name, start, end, radius, material):
    delta = Vector(end)-Vector(start)
    ob = cylinder(name, (Vector(start)+Vector(end))/2, radius, delta.length, material)
    ob.rotation_euler = delta.to_track_quat('Z','Y').to_euler()
    return ob

mapping = {
    '01 Suelo': oak, '02 Pared fondo': cream, '03 Pared lateral': cream,
    '04 Cama base': oak, '05 Colchon': ivory, '06 Cabecero': oak,
    '07 Almohada': ivory, '08 Escritorio tablero': oak,
    '09 Escritorio soporte A': oak, '10 Escritorio soporte B': oak,
    '11 Silla asiento': sage, '12 Silla base': black,
    '13 Silla respaldo': sage, '14 Alfombra': rugmat,
}
for name, material in mapping.items():
    ob = bpy.data.objects[name]
    assign(ob, material)
    ob.hide_render = False
    ob.hide_set(False)

# Floorboards with subtle gaps and staggered end joints.
for row in range(18):
    y = -2.45 + row * .275
    boundaries = [-2.92] + ([ -1.4, .5, 2.3] if row % 2 else [-2.1, -.2, 1.7]) + [2.92]
    for j, (a,b) in enumerate(zip(boundaries, boundaries[1:])):
        cube('Roble tabla %02d-%d' % (row,j), ((a+b)/2, y, .018),
             (b-a-.008, .267, .03), oak, .004)
cube('Zocalo posterior', (0,2.365,.1), (5.82,.045,.18), oak, .008)
cube('Zocalo lateral', (-2.865,0,.1), (.045,4.74,.18), oak, .008)

# More generous rug, kept out of the desk legs.
rug = bpy.data.objects['14 Alfombra']
rug.location = (.1,-1.36,.071)
rug.scale = (1.3,1.18,1)
for side in (-1,1):
    for i in range(55):
        x = -1.4+i*.055
        rod('Fleco de yute', (x,-1.36+side*.825,.073),
            (x+.008,-1.36+side*.91,.072), .003, rugmat)

# Organic duvet with a folded-over edge and light wrinkles.
verts=[]
faces=[]
nx,ny=65,65
for j in range(ny):
    v=j/(ny-1)
    y=-.91+v*2.03
    for i in range(nx):
        u=i/(nx-1)
        x=.49+u*2.12
        drop=max(0,(abs(u-.5)-.435)/.065)
        foot=max(0,(.07-v)/.07)
        z=.765-.22*drop**1.5-.12*foot
        z+=.014*math.sin(21*u+4*v)+.009*math.sin(46*v+8*u)
        z+=.06*math.exp(-((v-.92)/.045)**2)
        verts.append((x,y,z))
for j in range(ny-1):
    for i in range(nx-1):
        a=j*nx+i
        faces.append((a,a+1,a+nx+1,a+nx))
me=bpy.data.meshes.new('Tejido ondulado')
me.from_pydata(verts,[],faces)
duvet=tag(bpy.data.objects.new('Edredon salvia',me))
scene.collection.objects.link(duvet)
assign(duvet,sage)
for p in me.polygons: p.use_smooth=True
sub=duvet.modifiers.new('Suavizado textil','SUBSURF'); sub.levels=1
sol=duvet.modifiers.new('Grosor tejido','SOLIDIFY'); sol.thickness=.025

# Hide the block pillow, retain it as the original editable geometry.
bpy.data.objects['07 Almohada'].hide_render=True
bpy.data.objects['07 Almohada'].hide_set(True)
for x in (1.02,2.05):
    pillow=cube('Almohadon de lino', (x,1.66,.83), (.88,.62,.22), ivory, .1)
    pillow.rotation_euler[2]=-.05 if x<1.5 else .06
    sub=pillow.modifiers.new('Relleno suave','SUBSURF'); sub.levels=2
    for p in pillow.data.polygons:p.use_smooth=True
cube('Manta doblada', (1.55,-.48,.808), (2.06,.48,.065), ivory, .035)

# Slatted headboard detail.
for i in range(19):
    cube('Liston cabecero', (.56+i*.11,2.101,.61), (.055,.035,.95), oak, .012)

# Desk styling: closed notebook, pen, cup, a lamp.
cube('Cuaderno cubierta', (-1.47,1.53,.927), (.5,.34,.028), terracotta, .008)
cube('Cuaderno papel', (-1.47,1.53,.945), (.477,.322,.025), paper, .004)
rod('Boligrafo', (-1.66,1.53,.963),(-1.34,1.61,.963),.012,brass)
cylinder('Taza ceramica',(-.94,1.67,1.025),.075,.19,cream)
cylinder('Cafe',(-.94,1.67,1.123),.059,.006,soil)
cylinder('Lampara base',(-2.03,1.79,.934),.135,.035,brass)
rod('Lampara brazo',(-2.03,1.79,.95),(-2.03,1.79,1.43),.018,brass)
cylinder('Pantalla escritorio',(-2.03,1.79,1.48),.18,.17,cream,.095)

# Abstract framed wall art above the desk, built from geometry.
cube('Marco arte',(-1.43,2.354,2.05),(1.16,.07,1.16),oak,.01)
cube('Paspartu',(-1.43,2.31,2.05),(1.065,.014,1.065),paper,.002)
cube('Arte salvia',(-1.55,2.294,1.96),(.48,.008,.64),sage,.002)
disk=cylinder('Arte sol',(-1.21,2.278,2.29),.205,.012,terracotta)
disk.rotation_euler[0]=math.pi/2
cube('Arte horizonte',(-1.43,2.266,1.75),(.83,.01,.07),oak,.002)

# Bedside oak table on the left of the bed.
cylinder('Mesa auxiliar',(.06,1.65,.52),.32,.065,oak)
for a in (0,2.094,4.189):
    rod('Pata auxiliar',(.06+math.cos(a)*.23,1.65+math.sin(a)*.23,.045),
        (.06+math.cos(a)*.19,1.65+math.sin(a)*.19,.49),.025,oak)
cylinder('Jarron',(.06,1.65,.685),.105,.26,terracotta,.062)
for a in range(5):
    rod('Rama seca',(.06,1.65,.78),(.06+math.sin(a)*.17,1.65+math.cos(a)*.14,1.13+a*.018),.007,oak)

# Foliage softens the front left corner.
cylinder('Maceta',(-2.35,-1.65,.32),.23,.55,terracotta,.32)
cylinder('Tierra maceta',(-2.35,-1.65,.59),.29,.03,soil)
for i in range(13):
    a=i*2.399
    z=.84+(i%5)*.16
    end=(-2.35+math.cos(a)*.35,-1.65+math.sin(a)*.35,z)
    rod('Tallo',(-2.35,-1.65,.56),end,.009,leafmat)
    ob=sphere('Hoja',end,(.13,.045,.29),leafmat)
    ob.rotation_euler=(math.sin(a)*.65,math.cos(a)*.65,a)

# Ground and studio lighting: open dollhouse, not an enclosed interior.
ground=mat('Fondo arena',(.32,.29,.235),.94)
cube('Suelo estudio',(0,0,-.27),(200,200,.1),ground,0)

def area(name,loc,target,power,size,color):
    data=bpy.data.lights.new(name,'AREA')
    data.energy=power; data.shape='DISK'; data.size=size; data.color=color
    ob=tag(bpy.data.objects.new(name,data));scene.collection.objects.link(ob)
    ob.location=loc
    ob.rotation_euler=(Vector(target)-ob.location).to_track_quat('-Z','Y').to_euler()
    return ob

area('Ventana luz principal',(0,-3.8,6.5),(0,.5,0),1150,4.0,(1,.87,.69))
area('Relleno cielo',(4,-.5,4.5),(0,1,1),750,3.5,(.77,.87,1))
area('Luz cenital',(-1,2,5),(0,0,0),600,2.5,(1,.93,.8))
area('Lampara calida',(-2.03,1.79,1.37),(-2.03,1.79,.9),8,.15,(1,.57,.27))
scene.world.use_nodes=True
scene.world.node_tree.nodes['Background'].inputs['Color'].default_value=(.63,.72,.85,1)
scene.world.node_tree.nodes['Background'].inputs['Strength'].default_value=.22

camdata=bpy.data.cameras.new('Camara editorial')
cam=tag(bpy.data.objects.new('Camara editorial',camdata));scene.collection.objects.link(cam)
cam.location=(9,-12,8.8)
target=Vector((0,.15,1.02))
cam.rotation_euler=(target-cam.location).to_track_quat('-Z','Y').to_euler()
camdata.type='ORTHO';camdata.ortho_scale=9.3
scene.camera=cam
scene.render.engine='CYCLES'
scene.cycles.samples=96
scene.cycles.use_denoising=True
scene.cycles.max_bounces=8
scene.render.resolution_x=1500
scene.render.resolution_y=1500
scene.render.resolution_percentage=100
scene.render.image_settings.file_format='PNG'
scene.render.filepath=str(ROOT/'habitacion-realista.png')
scene.render.film_transparent=False
scene.view_settings.view_transform='AgX'
try:
    prefs=bpy.context.preferences.addons['cycles'].preferences
    prefs.compute_device_type='OPTIX'
    prefs.get_devices()
    for d in prefs.devices:d.use=(d.type=='OPTIX')
    if any(d.use for d in prefs.devices):scene.cycles.device='GPU'
except Exception as e:
    print('GPU unavailable; using CPU:',e)
for ob in bpy.context.selected_objects:ob.select_set(False)
bpy.context.view_layer.objects.active=cam
cam.select_set(True)
for screen in bpy.data.screens:
    for a in screen.areas:
        if a.type=='VIEW_3D':
            a.spaces.active.region_3d.view_perspective='CAMERA'
            a.spaces.active.shading.color_type='MATERIAL'
            a.spaces.active.overlay.show_overlays=False
bpy.ops.wm.save_as_mainfile(filepath=str(ROOT/'habitacion-realista.blend'))
print('DESKCTL_STYLE_READY',len(scene.objects),'objects',scene.cycles.device)
