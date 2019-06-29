/*
Copyright (c) 2009-2016-2018, UT-Battelle, LLC
All rights reserved

[DMRG++, Version 5.]
[by G.A., Oak Ridge National Laboratory]

UT Battelle Open Source Software License 11242008

OPEN SOURCE LICENSE

Subject to the conditions of this License, each
contributor to this software hereby grants, free of
charge, to any person obtaining a copy of this software
and associated documentation files (the "Software"), a
perpetual, worldwide, non-exclusive, no-charge,
royalty-free, irrevocable copyright license to use, copy,
modify, merge, publish, distribute, and/or sublicense
copies of the Software.

1. Redistributions of Software must retain the above
copyright and license notices, this list of conditions,
and the following disclaimer.  Changes or modifications
to, or derivative works of, the Software should be noted
with comments and the contributor and organization's
name.

2. Neither the names of UT-Battelle, LLC or the
Department of Energy nor the names of the Software
contributors may be used to endorse or promote products
derived from this software without specific prior written
permission of UT-Battelle.

3. The software and the end-user documentation included
with the redistribution, with or without modification,
must include the following acknowledgment:

"This product includes software produced by UT-Battelle,
LLC under Contract No. DE-AC05-00OR22725  with the
Department of Energy."

*********************************************************
DISCLAIMER

THE SOFTWARE IS SUPPLIED BY THE COPYRIGHT HOLDERS AND
CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED
WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
COPYRIGHT OWNER, CONTRIBUTORS, UNITED STATES GOVERNMENT,
OR THE UNITED STATES DEPARTMENT OF ENERGY BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE
OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH
DAMAGE.

NEITHER THE UNITED STATES GOVERNMENT, NOR THE UNITED
STATES DEPARTMENT OF ENERGY, NOR THE COPYRIGHT OWNER, NOR
ANY OF THEIR EMPLOYEES, REPRESENTS THAT THE USE OF ANY
INFORMATION, DATA, APPARATUS, PRODUCT, OR PROCESS
DISCLOSED WOULD NOT INFRINGE PRIVATELY OWNED RIGHTS.

*********************************************************
*/
#ifndef DMRG_MODELHELPER_H
#define DMRG_MODELHELPER_H

#include "PackIndices.h" // in PsimagLite
#include "Link.h"
#include "Concurrency.h"
#include "Vector.h"

/** \ingroup DMRG */
/*@{*/

/*! \file ModelHelperLocal.h
 *
 *  A class to contain state information about the Hamiltonian
 *  to help with the calculation of x+=Hy
 *
 */

namespace Dmrg {
template<typename LeftRightSuperType_>
class ModelHelperLocal {

	typedef PsimagLite::PackIndices PackIndicesType;
	typedef std::pair<SizeType,SizeType> PairType;

public:

	typedef LeftRightSuperType_ LeftRightSuperType;
	typedef typename LeftRightSuperType::OperatorsType OperatorsType;
	typedef typename OperatorsType::SparseMatrixType SparseMatrixType;
	typedef typename SparseMatrixType::value_type SparseElementType;
	typedef typename OperatorsType::OperatorType OperatorType;
	typedef typename OperatorsType::BasisType BasisType;
	typedef typename BasisType::BlockType BlockType;
	typedef typename BasisType::RealType RealType;
	typedef typename LeftRightSuperType::BasisWithOperatorsType BasisWithOperatorsType;
	typedef Link<SparseElementType> LinkType;
	typedef PsimagLite::Vector<SizeType>::Type VectorSizeType;
	typedef typename PsimagLite::Vector<SparseElementType>::Type VectorSparseElementType;
	typedef typename PsimagLite::Vector<SparseMatrixType>::Type VectorSparseMatrixType;
	typedef typename BasisType::QnType QnType;
	typedef typename PsimagLite::Vector<typename PsimagLite::Vector<SparseMatrixType*>::Type>::Type
	VectorVectorSparseMatrixType;

	ModelHelperLocal(SizeType m, const LeftRightSuperType& lrs)
	    : m_(m),
	      lrs_(lrs),
	      buffer_(lrs_.left().size()),
	      garbage_(PsimagLite::Concurrency::codeSectionParams.npthreads),
	      seen_(PsimagLite::Concurrency::codeSectionParams.npthreads)
	{
		PsimagLite::Concurrency::mutexInit(&mutex_);

		createBuffer();
		createAlphaAndBeta();
	}

	~ModelHelperLocal()
	{
		const SizeType n = garbage_.size();
		for (SizeType i = 0; i < n; ++i) {
			const SizeType m = garbage_[i].size();
			for (SizeType j = 0; j < m; ++j) {
				delete garbage_[i][j];
				garbage_[i][j] = 0;
			}
		}

		PsimagLite::Concurrency::mutexDestroy(&mutex_);
	}

	const SparseMatrixType& reducedOperator(char modifier,
	                                        SizeType i,
	                                        SizeType sigma,
	                                        const ProgramGlobals::SysOrEnvEnum type) const
	{

		assert(!BasisType::useSu2Symmetry());

		const SparseMatrixType* m = 0;
		PairType ii;
		if (type == ProgramGlobals::SysOrEnvEnum::SYSTEM) {
			ii = lrs_.left().getOperatorIndices(i,sigma);
			m = &(lrs_.left().getOperatorByIndex(ii.first).data);
		} else {
			assert(type == ProgramGlobals::SysOrEnvEnum::ENVIRON);
			ii = lrs_.right().getOperatorIndices(i,sigma);
			m =&(lrs_.right().getOperatorByIndex(ii.first).data);
		}

		m->checkValidity();
		if (modifier == 'N') return *m;

		assert(modifier == 'C');
		SizeType typeIndex = (type == ProgramGlobals::SysOrEnvEnum::SYSTEM) ? 0 : 1;
		SizeType packed = typeIndex + ii.first*2;
		const SizeType threadSelf = PsimagLite::Concurrency::threadSelf();
		const SizeType threadNum = threadNumberFromSelf(threadSelf);

		if (garbage_.size() <= threadNum || seen_.size() <= threadNum)
			err("reducedOperator: internal error\n");

		int indexOfSeen = PsimagLite::indexOrMinusOne(seen_[threadNum], packed);
		if (indexOfSeen >= 0) {
			assert(static_cast<SizeType>(indexOfSeen) < garbage_[threadNum].size());
			return *(garbage_[threadNum][indexOfSeen]);
		}

		SparseMatrixType* mc = new SparseMatrixType;
		transposeConjugate(*mc, *m);
		garbage_[threadNum].push_back(mc);
		seen_[threadNum].push_back(packed);
		mc->checkValidity();
		return *mc;
	}

	SizeType m() const { return m_; }

	static bool isSu2() { return false; }

	int size() const
	{
		int tmp = lrs_.super().partition(m_+1)-lrs_.super().partition(m_);
		return tmp; //reflection_.size(tmp);
	}

	const QnType& quantumNumber() const
	{
		return lrs_.super().qnEx(m_);
	}

	//! Does matrixBlock= (AB), A belongs to pSprime and B
	// belongs to pEprime or viceversa (inter)
	void fastOpProdInter(SparseMatrixType const &A,
	                     SparseMatrixType const &B,
	                     SparseMatrixType &matrixBlock,
	                     const LinkType& link) const
	{
		RealType fermionSign = (link.fermionOrBoson == ProgramGlobals::FermionOrBosonEnum::FERMION)
		        ? -1 : 1;

		//! work only on partition m
		if (link.type==ProgramGlobals::ConnectionEnum::ENVIRON_SYSTEM)  {
			LinkType link2 = link;
			link2.value *= fermionSign;
			link2.type = ProgramGlobals::ConnectionEnum::SYSTEM_ENVIRON;
			fastOpProdInter(B,A,matrixBlock,link2);
			return;
		}

		int m = m_;
		int offset = lrs_.super().partition(m);
		int total = lrs_.super().partition(m+1) - offset;
		int counter=0;
		matrixBlock.resize(total,total);

		int i;
		for (i=0;i<total;i++) {
			// row i of the ordered product basis
			matrixBlock.setRow(i,counter);
			int alpha=alpha_[i];
			int beta=beta_[i];

			SparseElementType fsValue = (fermionSign < 0 && fermionSigns_[i])
			        ? -link.value
			        : link.value;

			for (int k=A.getRowPtr(alpha);k<A.getRowPtr(alpha+1);k++) {
				int alphaPrime = A.getCol(k);
				for (int kk=B.getRowPtr(beta);kk<B.getRowPtr(beta+1);kk++) {
					int betaPrime= B.getCol(kk);
					int j = buffer_[alphaPrime][betaPrime];
					if (j<0) continue;
					/* fermion signs note:
					here the environ is applied first and has to "cross"
					the system, hence the sign factor pSprime.fermionicSign(alpha,tmp)
					*/
					SparseElementType tmp = A.getValue(k) * B.getValue(kk)*fsValue;
					//if (tmp==static_cast<MatrixElementType>(0.0)) continue;
					matrixBlock.pushCol(j);
					matrixBlock.pushValue(tmp);
					counter++;
				}
			}
		}

		matrixBlock.setRow(i,counter);
	}

	// Does x+= (AB)y, where A belongs to pSprime and B  belongs to pEprime or
	// viceversa (inter)
	// Has been changed to accomodate for reflection symmetry
	void fastOpProdInter(VectorSparseElementType& x,
	                     const VectorSparseElementType& y,
	                     const SparseMatrixType& A,
	                     const SparseMatrixType& B,
	                     const LinkType& link) const
	{
		RealType fermionSign =  (link.fermionOrBoson == ProgramGlobals::FermionOrBosonEnum::FERMION)
		        ? -1 : 1;

		if (link.type==ProgramGlobals::ConnectionEnum::ENVIRON_SYSTEM)  {
			LinkType link2 = link;
			link2.value *= fermionSign;
			link2.type = ProgramGlobals::ConnectionEnum::SYSTEM_ENVIRON;
			fastOpProdInter(x,y,B,A,link2);
			return;
		}

		//! work only on partition m
		int m = m_;
		int offset = lrs_.super().partition(m);
		int total = lrs_.super().partition(m+1) - offset;

		for (int i=0;i<total;++i) {
			// row i of the ordered product basis
			int alpha=alpha_[i];
			int beta=beta_[i];
			SparseElementType sum = 0.0;
			int startkk = B.getRowPtr(beta);
			int endkk = B.getRowPtr(beta+1);
			int startk = A.getRowPtr(alpha);
			int endk = A.getRowPtr(alpha+1);
			/* fermion signs note:
			 * here the environ is applied first and has to "cross"
			 * the system, hence the sign factor pSprime.fermionicSign(alpha,tmp)
			 */

			SparseElementType fsValue = (fermionSign < 0 && fermionSigns_[i])
			        ? -link.value
			        : link.value;

			for (int k=startk;k<endk;++k) {
				int alphaPrime = A.getCol(k);
				SparseElementType tmp2 = A.getValue(k) *fsValue;
				const typename PsimagLite::Vector<int>::Type& bufferTmp =
				        buffer_[alphaPrime];

				for (int kk=startkk;kk<endkk;++kk) {
					int betaPrime= B.getCol(kk);
					int j = bufferTmp[betaPrime];
					if (j<0) continue;

					SparseElementType tmp = tmp2 * B.getValue(kk);
					sum += tmp * y[j];
				}
			}

			x[i] += sum;
		}
	}

	// Let H_{alpha,beta; alpha',beta'} =
	// basis2.hamiltonian_{alpha,alpha'} \delta_{beta,beta'}
	// Let H_m be  the m-th block (in the ordering of basis1) of H
	// Then, this function does x += H_m * y
	// This is a performance critical function
	// Has been changed to accomodate for reflection symmetry
	void hamiltonianLeftProduct(VectorSparseElementType& x,
	                            const VectorSparseElementType& y) const
	{
		int m = m_;
		int offset = lrs_.super().partition(m);
		int i,k,alphaPrime;
		int bs = lrs_.super().partition(m+1)-offset;
		const SparseMatrixType& hamiltonian = lrs_.left().hamiltonian();
		SizeType ns = lrs_.left().size();
		SparseElementType sum = 0.0;
		PackIndicesType pack(ns);
		for (i=0;i<bs;i++) {
			SizeType r,beta;
			pack.unpack(r,beta,lrs_.super().permutation(i+offset));

			// row i of the ordered product basis
			for (k=hamiltonian.getRowPtr(r);k<hamiltonian.getRowPtr(r+1);k++) {
				alphaPrime = hamiltonian.getCol(k);
				int j = buffer_[alphaPrime][beta];
				if (j<0) continue;
				sum += hamiltonian.getValue(k)*y[j];
			}

			x[i] += sum;
			sum = 0.0;
		}
	}

	// Let  H_{alpha,beta; alpha',beta'} =
	// basis2.hamiltonian_{beta,beta'} \delta_{alpha,alpha'}
	// Let H_m be  the m-th block (in the ordering of basis1) of H
	// Then, this function does x += H_m * y
	// This is a performance critical function
	void hamiltonianRightProduct(VectorSparseElementType& x,
	                             const VectorSparseElementType& y) const
	{
		int m = m_;
		int offset = lrs_.super().partition(m);
		int i,k;
		int bs = lrs_.super().partition(m+1)-offset;
		const SparseMatrixType& hamiltonian = lrs_.right().hamiltonian();
		SizeType ns = lrs_.left().size();
		SparseElementType sum = 0.0;
		PackIndicesType pack(ns);
		for (i=0;i<bs;i++) {
			SizeType alpha,r;
			pack.unpack(alpha,r,lrs_.super().permutation(i+offset));

			// row i of the ordered product basis
			for (k=hamiltonian.getRowPtr(r);k<hamiltonian.getRowPtr(r+1);k++) {
				int j = buffer_[alpha][hamiltonian.getCol(k)];
				if (j<0) continue;
				sum += hamiltonian.getValue(k)*y[j];
			}

			x[i] += sum;
			sum = 0.0;
		}
	}

	// if option==true let H_{alpha,beta; alpha',beta'} =
	// basis2.hamiltonian_{alpha,alpha'} \delta_{beta,beta'}
	// if option==false let  H_{alpha,beta; alpha',beta'} =
	// basis2.hamiltonian_{beta,beta'} \delta_{alpha,alpha'}
	// returns the m-th block (in the ordering of basis1) of H
	// Note: USed only for debugging
	void calcHamiltonianPart(SparseMatrixType &matrixBlock,
	                         bool option) const
	{
		int m  = m_;
		SizeType offset = lrs_.super().partition(m);
		int k,alphaPrime=0,betaPrime=0;
		int bs = lrs_.super().partition(m+1)-offset;
		SizeType ns=lrs_.left().size();
		SparseMatrixType hamiltonian;
		if (option) {
			hamiltonian = lrs_.left().hamiltonian();
		} else {
			hamiltonian = lrs_.right().hamiltonian();
		}

		matrixBlock.resize(bs,bs);

		int counter=0;
		PackIndicesType pack(ns);
		for (SizeType i=offset;i<lrs_.super().partition(m+1);i++) {
			matrixBlock.setRow(i-offset,counter);
			SizeType alpha,beta;
			pack.unpack(alpha,beta,lrs_.super().permutation(i));
			SizeType r=beta;
			if (option) {
				betaPrime=beta;
				r = alpha;
			} else {
				alphaPrime=alpha;
				r=beta;
			}

			assert(r<hamiltonian.rows());
			// row i of the ordered product basis
			for (k=hamiltonian.getRowPtr(r);k<hamiltonian.getRowPtr(r+1);k++) {

				if (option) alphaPrime = hamiltonian.getCol(k);
				else 	    betaPrime  = hamiltonian.getCol(k);
				SizeType j = lrs_.super().permutationInverse(alphaPrime + betaPrime*ns);
				if (j<offset || j>=lrs_.super().partition(m+1)) continue;
				SparseElementType tmp = hamiltonian.getValue(k);
				matrixBlock.pushCol(j-offset);
				matrixBlock.pushValue(tmp);
				counter++;
			}
		}

		matrixBlock.setRow(lrs_.super().partition(m+1)-offset,counter);
	}

	const LeftRightSuperType& leftRightSuper() const
	{
		return lrs_;
	}

private:

	void createBuffer()
	{
		SizeType ns=lrs_.left().size();
		SizeType ne=lrs_.right().size();
		int offset = lrs_.super().partition(m_);
		int total = lrs_.super().partition(m_+1) - offset;

		typename PsimagLite::Vector<int>::Type  tmpBuffer(ne);
		for (SizeType alphaPrime=0;alphaPrime<ns;alphaPrime++) {
			for (SizeType betaPrime=0;betaPrime<ne;betaPrime++) {
				tmpBuffer[betaPrime] = lrs_.super().
				        permutationInverse(alphaPrime + betaPrime*ns) -offset;
				if (tmpBuffer[betaPrime]>=total) tmpBuffer[betaPrime]= -1;
			}
			buffer_[alphaPrime]=tmpBuffer;
		}
	}

	void createAlphaAndBeta()
	{
		SizeType ns=lrs_.left().size();
		int offset = lrs_.super().partition(m_);
		int total = lrs_.super().partition(m_+1) - offset;

		PackIndicesType pack(ns);
		alpha_.resize(total);
		beta_.resize(total);
		fermionSigns_.resize(total);
		for (int i=0;i<total;i++) {
			// row i of the ordered product basis
			pack.unpack(alpha_[i],beta_[i],lrs_.super().permutation(i+offset));
			int fs = lrs_.left().fermionicSign(alpha_[i],-1);
			fermionSigns_[i] = (fs < 0) ? true : false;
		}
	}

	SizeType threadNumberFromSelf(SizeType threadSelf) const
	{
		PsimagLite::Concurrency::mutexLock(&mutex_);
		int threadPreNum = PsimagLite::indexOrMinusOne(threadSelves_, threadSelf);
		if (threadPreNum < 0) {
			threadPreNum = threadSelves_.size();
			threadSelves_.push_back(threadSelf);
		}

		PsimagLite::Concurrency::mutexUnlock(&mutex_);

		return threadPreNum;
	}


	int m_;
	const LeftRightSuperType& lrs_;
	typename PsimagLite::Vector<PsimagLite::Vector<int>::Type>::Type buffer_;
	typename PsimagLite::Vector<SizeType>::Type alpha_,beta_;
	typename PsimagLite::Vector<bool>::Type fermionSigns_;
	mutable VectorVectorSparseMatrixType garbage_;
	mutable typename PsimagLite::Vector<BlockType>::Type seen_;
	mutable PsimagLite::Concurrency::MutexType mutex_;
	mutable VectorSizeType threadSelves_;
}; // class ModelHelperLocal
} // namespace Dmrg
/*@}*/

#endif

