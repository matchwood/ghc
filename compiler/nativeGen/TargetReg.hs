
{-# OPTIONS -fno-warn-tabs #-}
-- The above warning supression flag is a temporary kludge.
-- While working on this module you are encouraged to remove it and
-- detab the module (please do the detabbing in a separate patch). See
--     http://hackage.haskell.org/trac/ghc/wiki/Commentary/CodingStyle#TabsvsSpaces
-- for details

-- | Hard wired things related to registers.
--	This is module is preventing the native code generator being able to 
--	emit code for non-host architectures.
--
--	TODO: Do a better job of the overloading, and eliminate this module.
--	We'd probably do better with a Register type class, and hook this to 
--	Instruction somehow.
--
--	TODO: We should also make arch specific versions of RegAlloc.Graph.TrivColorable

module TargetReg (
	targetVirtualRegSqueeze,
	targetRealRegSqueeze,
	targetClassOfRealReg,
	targetMkVirtualReg,
	targetWordSize,
	targetRegDotColor,
	targetClassOfReg
)

where

#include "HsVersions.h"

import Reg
import RegClass
import Size

import CmmType	(wordWidth)
import Outputable
import Unique
import FastTypes
import Platform

import qualified X86.Regs       as X86
import qualified X86.RegInfo    as X86

import qualified PPC.Regs       as PPC

import qualified SPARC.Regs     as SPARC

targetVirtualRegSqueeze :: Platform -> RegClass -> VirtualReg -> FastInt
targetVirtualRegSqueeze platform
    = case platformArch platform of
      ArchX86       -> X86.virtualRegSqueeze
      ArchX86_64    -> X86.virtualRegSqueeze
      ArchPPC       -> PPC.virtualRegSqueeze
      ArchSPARC     -> SPARC.virtualRegSqueeze
      ArchPPC_64    -> panic "targetVirtualRegSqueeze ArchPPC_64"
      ArchARM _ _ _ -> panic "targetVirtualRegSqueeze ArchARM"
      ArchUnknown   -> panic "targetVirtualRegSqueeze ArchUnknown"

targetRealRegSqueeze :: Platform -> RegClass -> RealReg -> FastInt
targetRealRegSqueeze platform
    = case platformArch platform of
      ArchX86       -> X86.realRegSqueeze
      ArchX86_64    -> X86.realRegSqueeze
      ArchPPC       -> PPC.realRegSqueeze
      ArchSPARC     -> SPARC.realRegSqueeze
      ArchPPC_64    -> panic "targetRealRegSqueeze ArchPPC_64"
      ArchARM _ _ _ -> panic "targetRealRegSqueeze ArchARM"
      ArchUnknown   -> panic "targetRealRegSqueeze ArchUnknown"

targetClassOfRealReg :: Platform -> RealReg -> RegClass
targetClassOfRealReg platform
    = case platformArch platform of
      ArchX86       -> X86.classOfRealReg
      ArchX86_64    -> X86.classOfRealReg
      ArchPPC       -> PPC.classOfRealReg
      ArchSPARC     -> SPARC.classOfRealReg
      ArchPPC_64    -> panic "targetClassOfRealReg ArchPPC_64"
      ArchARM _ _ _ -> panic "targetClassOfRealReg ArchARM"
      ArchUnknown   -> panic "targetClassOfRealReg ArchUnknown"

-- TODO: This should look at targetPlatform too
targetWordSize :: Size
targetWordSize = intSize wordWidth

targetMkVirtualReg :: Platform -> Unique -> Size -> VirtualReg
targetMkVirtualReg platform
    = case platformArch platform of
      ArchX86       -> X86.mkVirtualReg
      ArchX86_64    -> X86.mkVirtualReg
      ArchPPC       -> PPC.mkVirtualReg
      ArchSPARC     -> SPARC.mkVirtualReg
      ArchPPC_64    -> panic "targetMkVirtualReg ArchPPC_64"
      ArchARM _ _ _ -> panic "targetMkVirtualReg ArchARM"
      ArchUnknown   -> panic "targetMkVirtualReg ArchUnknown"

targetRegDotColor :: Platform -> RealReg -> SDoc
targetRegDotColor platform
    = case platformArch platform of
      ArchX86       -> X86.regDotColor platform
      ArchX86_64    -> X86.regDotColor platform
      ArchPPC       -> PPC.regDotColor
      ArchSPARC     -> SPARC.regDotColor
      ArchPPC_64    -> panic "targetRegDotColor ArchPPC_64"
      ArchARM _ _ _ -> panic "targetRegDotColor ArchARM"
      ArchUnknown   -> panic "targetRegDotColor ArchUnknown"


targetClassOfReg :: Platform -> Reg -> RegClass
targetClassOfReg platform reg
 = case reg of
   RegVirtual vr -> classOfVirtualReg vr
   RegReal rr -> targetClassOfRealReg platform rr


