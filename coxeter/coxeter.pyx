import tqdm
from PIL import Image
from math import sin, cos, tan, sqrt, floor, pi
from cmath import exp
#from mpmath import ellipfun
cimport numpy as np
import numpy as np

import random
import exceptions


# COLOURS
def HTMLColorToRGB(colorstring):
    """ convert #RRGGBB to an (R, G, B) tuple """
    colorstring = colorstring.strip()
    if colorstring[0] == '#': colorstring = colorstring[1:]
    if len(colorstring) != 6:
        raise exceptions.ColorFormatError(
            "input #%s is not in #RRGGBB format" %colorstring)
    r, g, b = colorstring[:2], colorstring[2:4], colorstring[4:]
    try:
        r, g, b = [int(n, 16) for n in (r, g, b)]
    except ValueError:
        raise exceptions.ColorFormatError(
                "input #%s is not composed of hex literals" %colorstring)
    return (r, g, b, 255)


# geom functions
cdef extern from "complex.h":
    float creal(complex)
cdef extern from "complex.h":
    float cimag(complex)
cdef extern from "complex.h":
    complex conj(complex)
cdef extern from "math.h":
    float tanh(float)
cdef extern from "complex.h":
    complex asin(complex)
cdef extern from "complex.h":
    complex csin(complex)
cdef extern from "complex.h":
    complex ccos(complex)

cdef float abs2(complex w):
    return creal(w)*creal(w) + cimag(w)*cimag(w)

cdef complex mobius_translation (complex w,complex a):
    return (w+a)/(1+w*a)
    
cdef float signum(float x):
    return (x>0) - (x<0)
cdef float rabs (float x):
    return x * signum(x)


# jacobi elliptic function
cdef int JACOBI_ITERATIONS = 7
temp_covera_list = []
a = 1.0
b = 1.0/sqrt(2)
c = 1.0/sqrt(2)
for i in range(JACOBI_ITERATIONS + 1):
    temp_covera_list.append(c/a)
    ta,tb,tc = 0.5 * (a+b) , sqrt(a*b) , 0.5*(a-b)
    a,b,c = ta,tb,tc


temp_covera = temp_covera_list
cdef float a_n = a


cdef complex jacobi_cn_opt(complex w): #doesn't work well for Im(w) =/= 0 ???
    global temp_covera,a_n

    cdef complex phi_amplitude = (2**JACOBI_ITERATIONS) * a_n * w
    for i in range(JACOBI_ITERATIONS):
        phi_amplitude = 0.5*(phi_amplitude + asin( temp_covera[ JACOBI_ITERATIONS-i] * csin(phi_amplitude) ) )

    return ccos(phi_amplitude)

cdef float sqrt2 = sqrt(2)
cdef complex jacobi_cn(w):
    if (creal(w) < -K_e):
        return -(jacobi_cn((-2*K_e - w)))

    if ( cimag(w) > creal(w) + K_e):
        return  1j * (jacobi_cn( -K_e + (-1j)*(w + K_e) ) )
    if (cimag(w) < - creal(w) - K_e):
        return  -1j * (jacobi_cn( -K_e + (1j)*(w + K_e) ) )

    #pade approximant 8,8
    cdef complex w2,w4,w6,w8,t2,t4,t6,t8

    w2 = w*w
    w4 = w2*w2
    w6 = w4*w2
    w8 = w4*w4

    t2 = w2/4.
    t4 = w4/120.
    t6 = w6/960.
    t8 = w8/249600.

    return (1.0 - t2 - t4 - t6 + t8) / (1.0 + t2 - t4 + t6 + t8)


cdef float K_e = 1.85407467730137191843385034719526004621759 # enough digits for you?



#bilinear sampling
cdef np.ndarray lerp(np.ndarray a, np.ndarray b, float coord):
    #if isinstance(a, tuple):
    #    return tuple([lerp(c, d, coord) for c,d in zip(a,b)])
    cdef float ratio = coord - floor(coord) 
    cdef np.ndarray out = np.rint(a * (1.0-ratio) + b * ratio).astype(int)
    return out


cdef tuple bilinear(np.ndarray im, float y,float x):
    cdef int x1,y1,x2,y2
    x1, y1 = int(floor(x)), int(floor(y))
    x2, y2 = x1+1, y1+1
    cdef np.ndarray left = lerp(im[y1, x1,:], im[y1, x2,:], x)
    cdef np.ndarray right = lerp(im[y2, x1,:], im[y2, x2,:], x)
    cdef np.ndarray out = lerp(left, right, y)
    return (out[0],out[1],out[2],255)

# precalc defs

cdef complex rot2pip
cdef float tanpip
cdef complex centre,rotator, pivot_vertex, vertex_rotator
cdef doubletanpip,curtanpip
cdef float r2,r,d



cdef bint do_double

cdef enum DoubleModeType:
    DoubleAlternating,DoubleRotate


# fundamental region

cdef bint in_fund(complex zz):
    global do_double, doubletanpip, tanpip, rot2pip, r2, centre
    if do_double:
        return (
            (cimag(zz) >=0) and
            (cimag(zz) < doubletanpip * creal(zz)) and
            ((abs2(zz-centre) > r2) and ( abs2(zz - centre*rot2pip)> r2)))
    else:
        return (
            (zz.imag >= 0) and
            (zz.imag < tanpip * zz.real) and
            (abs2(zz - centre) > r2 ))

# flipper

cdef complex cI = 1j



cdef rotate_about_apotheme(complex zz,complex pivot):
    global vertex_rotator
    return mobius_translation( vertex_rotator *  mobius_translation(zz,-pivot)  , pivot)



def main(
        p,
        q,
        size_original,
        input_image,
        mobius,
        polygon,
        max_iterations,
        zoom,
        translate               = 0,
        flip                    = False,
        doubled                 = False,
        quadrupled              = False,
        alternating             = False,
        oversampling            = None,
        template                = False,
        truncate_uniform        = False,
        truncate_complete       = False,
        borders                 = -1,
        colours                 = [],
        half_plane              = False,
        equidistant             = False,
        squircle                = False):
    global do_double, doubletanpip, tanpip, rot2pip, r2, centre, r, d

    cdef bint do_flip = flip
    do_double = doubled

    cdef bint do_quadruple = quadrupled

    if (do_quadruple):
        do_double = True

    cdef bint do_equidistant = equidistant
    cdef bint do_squircle = squircle
    
    cdef bint do_borders = (borders > 0)
    cdef float border_width = borders*borders
    cdef bint do_mandelbrot = False

    cdef DoubleModeType double_mode = DoubleRotate

    if (alternating):
        double_mode = DoubleAlternating


    if q < 0:#infinity
        q = 2**10

    if (p - 2) * (q - 2) <= 4:
        raise exceptions.NotHyperbolicError(
            "(p - 2) * (q - 2) < 4: tessellation is not hyperbolic")

    if ((double_mode==DoubleAlternating) and p % 2):
        raise exceptions.AlternatingModeError(
            "alternating mode cannot be used with odd p.")

    oversampled_size = size_original * oversampling
    shape = (oversampled_size, oversampled_size)

    #Input sector precalc

    phiangle = pi / 2 - (pi / p + pi / q)

    d = sqrt((cos(pi/q)**2) / (cos(pi/q)**2 - sin(pi/p)**2))
    r = sqrt((sin(pi/p)**2) / (cos(pi/q)**2 - sin(pi/p)**2))

    R = sqrt(r*r + d*d - 2*r*d*cos(phiangle)) # circumscribed circle radius
    centers_distance = 2 * (d-r) / (1+(d-r)**2) # distance between centres of adjacent polygons


    a = cos(phiangle)*r
    x_input_sector = d-a
    y_input_sector = sin(phiangle)*r
    cdef float input_sector = max(x_input_sector, y_input_sector)


    # Colours parsing

    col_bg, col_primary , col_secundary, col_truncation, col_divergent, col_borders = map(HTMLColorToRGB, colours)

    # palette = [ (random.randint(0,255),random.randint(0,255),random.randint(0,255),255) for j in range(15) ]

    # average input colour

    if input_image:
        inimage_pixels = np.array(input_image.getdata(), np.uint8).reshape(input_image.size[1],input_image.size[0],3)
        inW, inH = input_image.size
        ar,ag,ab = 0,0,0
        count = 0

        for x in range(inW):
            for y in range(inH):
                temp = inimage_pixels[y,x]
                ar+=temp[0]
                ag+=temp[1]
                ab+=temp[2]
                count += 1
        average_colour = (ar // count, ag // count, ab // count)


    # precalc
    rot2pip = exp(1j*2*pi/float(p))
    rotpip = exp(1j*pi/float(p))
    tanpip = tan(pi/float(p))


    if (not do_double):
        rotator = rot2pip
        curtanpip = tanpip
    else:
        rotator = rot2pip ** 2
        # halfrot = exp(1j*2*pi/float(p))
        # tanpip = tan(pi/float(p))
        doubletanpip = tan(2*pi/float(p))
        curtanpip = doubletanpip


    centre = complex(d,0) # center of inversion circle
    r2 = r*r

    pivot_vertex = exp(1j * pi/float(p)) * R # pivot vertex for rotation.
    vertex_rotator = exp(-2j * pi/float(q))

    rot_centre = rot2pip * centre
    if truncate_uniform or truncate_complete:
        centre_truncation_uniform = exp(1j*pi/float(p)) * centre
    if truncate_complete:
        rprime2 = abs2( centre_truncation_uniform - (d-r) )



    # template

    if (template):
        templimg = Image.new("RGB",(size_original,size_original),"white")
        templimg_pixels = templimg.load()
        
        unit = tanh(abs(R)/2) / 8.0

        for i in range(size_original):
            for j in range(size_original):
                zz = (i + 1j*j)/(float(size_original))*input_sector
                if in_fund(zz):
                    templimg_pixels[i,j] = col_primary
                    if int(floor(tanh(abs(zz)/2) / unit))%2 == 0:
                        templimg_pixels[i,j] = col_secundary
                    
        return templimg

    # create main buffer

    out = Image.new("RGB", shape, col_bg)
    out_pixels = out.load()

    # render loop

    cdef int COLUMNS = shape[0]
    cdef int LINES = shape[1]
    cdef int xl,yl
    cdef complex z,nz

    cdef int max_iterations_int = max_iterations
    cdef int it

    cdef bint endflag, outflag
    cdef int parity = 0      # count transformation parity

    cdef int xx,yy

    for xl in tqdm.trange(COLUMNS):
        for yl in range(LINES):
            if (half_plane):
                X = 2*float(xl)/shape[0]        
                Y = 2*float(shape[1]-yl)/shape[1]  
                w = complex(X,Y)
                z = (w-1j)/(-1j*w + 1)
            else:
                # should allow for arbitrary affine maps
                X = (2*float(xl)/shape[0]-1. ) 
                Y = (2*float(yl)/shape[1]-1. )
                z = translate + complex(X,Y) * zoom


            z += 0.0001*(random.random()+1j) # <- fix boundary errors

            if do_equidistant:
                # equidistant azimuthal
                norm = tanh(abs(z)/2)
                z = z / abs(z) * norm

            if do_squircle:
#                z = (1-1j)/sqrt2 * jacobi_cn(K_e * ( (1+1j)/2.0 * z - 1) )
                 if (rabs(creal(z)) > 1) or (rabs(cimag(z)) > 1):
                     continue
                 z = jacobi_cn( K_e * ((1+1j)/2.0 * z - 1))

            if (do_mandelbrot):
                #mandelbrot
                nz = z
                for k in range(20):
                    nz = nz*nz + z
                z = nz


            # exclude if outside the disk
            if abs2(z) > 1.0:
                continue

            #mobius
            if mobius:
                z = (z+mobius)/(1+ z*mobius)

            endflag = False # detect loop
            outflag = False # detect out of disk
            parity = 0      # count transformation parity

            #if abs2( z - pivot_vertex ) < 0.001:
            #        outflag = True
            #        continue

            for it in range(max_iterations_int): 

                
                # rotate z into fundamental wedge
                emergency = 0
                while((rabs(z.imag) > curtanpip * z.real)):
                    if (z.imag < 0):
                        z *= rotator
                    else:
                        z /= rotator
                    emergency += 1
                    if emergency > 500:
                        break

                if in_fund(z):
                    break
                
                # flip

                if (not do_double) or (double_mode == DoubleAlternating):
                    z = conj(z)
                    if (not polygon):
                        parity += 1
                else:
                    # Double and rotating
                    if cimag(z) > 0:
                        z/= rot2pip
                        parity+=1
                    else:
                        z*= rot2pip
                        parity+=1


                if in_fund(z):
                    break
                
                if do_flip:
                    #flipper = rot2pip if (double_mode == DoubleAlternating) else -1

                    # Invert, then rotate

                    # invert wrt centre
                    w = z - centre
                    w = r2 / conj(w)
                    nz = centre + w

                    if double_mode == DoubleAlternating:
                        nz *= rot2pip
                    else:
                        nz = conj(nz)

                    if (abs2(nz) < abs2(z)):
                        z = nz
                        parity += 1


                    # Rotate, then invert

                    if double_mode == DoubleAlternating:
                        nz = rot2pip * z
                    else:
                        nz = conj(z)


                    w = nz - centre
                    w = r2 / conj(w)
                    nz = centre + w

                    if (abs2(nz) < abs2(z)):
                        z = nz
                        parity += 1

                else:


                    # bring closer

                    # invert

                    local_centre = centre if ((not do_double) or (rabs(z.imag) < tanpip * z.real)) else rot_centre

                    w = z - local_centre
                    # w = w * r2 / abs2(w)
                    w = r2 / conj(w) # optimization
                    nz = local_centre + w
                    
                    if (abs2(nz) < abs2(z)):
                        z = nz    
                        parity += 1

                if in_fund(z):
                    break

                if it == max_iterations - 1:
                    endflag = True

            # produce colour
            if (in_fund(z)):
                if input_image:
                    # C -> image_space

                    xx = int(z.real/input_sector*inW) % inW
                    if (not do_quadruple):
                        yy = int(z.imag/input_sector*inH) % inH
                    else:
                        yyt = (z.imag/input_sector)*(inH/2.0)
                        if (parity%2 == 1):
                            yyt = - yyt
                        yyt += inH/2.0
                        yy = int(yyt)
                    

                    try:
                        c =  bilinear(inimage_pixels,yy,xx ) # bilinear(inimage_pixels,xx,yy)
                    except IndexError:
                        c = average_colour #(0,255,255,255)
                else:
                    # c = (int(z.real*255),int(z.imag*255),0,255)
                    c = col_secundary if (parity % 2 == 0) else col_primary
                    #c = palette[ parity % 3]
                    if truncate_uniform and (abs2(z-centre_truncation_uniform) < r2):
                        c = col_truncation
                    if truncate_complete and (abs2(z-centre_truncation_uniform) < rprime2):
                        c = col_truncation
                    
                    # borders
                    if do_borders:
                        if (abs2(z-d) < r2 + border_width):
                            c = col_borders

            else:
                c = (0,255,0,255) # error?

            if (endflag):
                if input_image:
                    c = average_colour
                else:
                    c = col_divergent # too many iters

            if (outflag):
                c = (255,0,255,255) # out of circle

            out_pixels[xl,yl] = c

    if (oversampling > 1):
        out = out.resize((size_original, size_original), Image.LANCZOS)

    return out
